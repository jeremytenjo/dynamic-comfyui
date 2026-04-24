from __future__ import annotations

import shutil
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from threading import Lock

from rich.table import Table

from .common import download_file, effective_free_bytes, format_size_for_display, probe_remote_file_size, run
from .manifests import CustomNode, FileSpec
from .ui import console, print_error, print_info, print_success, print_warning


@dataclass(frozen=True)
class NodeInstallFailure:
    repo_dir: str
    step: str
    error: str


@dataclass(frozen=True)
class FileInstallFailure:
    target: str
    error: str


def install_custom_nodes(
    custom_nodes: list[CustomNode], custom_nodes_dir: Path, *, on_progress: callable | None = None
) -> list[NodeInstallFailure]:
    if not custom_nodes:
        print_info("No custom nodes defined in install manifest; skipping node installation.")
        return []

    failures: list[NodeInstallFailure] = []
    total_nodes = len(custom_nodes)
    completed_nodes = 0
    for index, node in enumerate(custom_nodes, start=1):
        node_prefix = f"[node {index}/{total_nodes}]"
        node_path = custom_nodes_dir / node.repo_dir
        if node_path.is_dir():
            completed_nodes += 1
            remaining_nodes = total_nodes - completed_nodes
            print_success(
                f"{node_prefix} {node.repo_dir}: already installed "
                f"({completed_nodes}/{total_nodes} complete, remaining {remaining_nodes})"
            )
            if on_progress:
                on_progress()
            continue

        if node_path.exists():
            shutil.rmtree(node_path)
        try:
            print_info(f"{node_prefix} {node.repo_dir}: clone started")
            run(["git", "clone", node.repo, str(node_path)], quiet=True)
            print_info(f"{node_prefix} {node.repo_dir}: clone complete")
        except Exception as exc:
            failures.append(NodeInstallFailure(repo_dir=node.repo_dir, step="git clone", error=str(exc)))
            completed_nodes += 1
            remaining_nodes = total_nodes - completed_nodes
            print_error(f"{node_prefix} {node.repo_dir}: clone failed ({exc})")
            print_info(f"Custom nodes progress: {completed_nodes}/{total_nodes} complete (remaining {remaining_nodes})")
            if on_progress:
                on_progress()
            continue

        requirements = node_path / "requirements.txt"
        if requirements.is_file():
            try:
                print_info(f"{node_prefix} {node.repo_dir}: requirements install started")
                run(["python3", "-m", "pip", "install", "--no-cache-dir", "-r", str(requirements)], quiet=True)
                print_info(f"{node_prefix} {node.repo_dir}: requirements install complete")
            except Exception as exc:
                failures.append(NodeInstallFailure(repo_dir=node.repo_dir, step="requirements install", error=str(exc)))
                completed_nodes += 1
                remaining_nodes = total_nodes - completed_nodes
                print_error(f"{node_prefix} {node.repo_dir}: requirements install failed ({exc})")
                print_info(f"Custom nodes progress: {completed_nodes}/{total_nodes} complete (remaining {remaining_nodes})")
                if on_progress:
                    on_progress()
                continue
        else:
            print_info(f"{node_prefix} {node.repo_dir}: requirements skipped")

        install_py = node_path / "install.py"
        if install_py.is_file():
            try:
                print_info(f"{node_prefix} {node.repo_dir}: install.py started")
                run(["python3", "install.py"], cwd=node_path, quiet=True)
                print_info(f"{node_prefix} {node.repo_dir}: install.py complete")
            except Exception as exc:
                failures.append(NodeInstallFailure(repo_dir=node.repo_dir, step="install.py", error=str(exc)))
                completed_nodes += 1
                remaining_nodes = total_nodes - completed_nodes
                print_error(f"{node_prefix} {node.repo_dir}: install.py failed ({exc})")
                print_info(f"Custom nodes progress: {completed_nodes}/{total_nodes} complete (remaining {remaining_nodes})")
                if on_progress:
                    on_progress()
                continue
        else:
            print_info(f"{node_prefix} {node.repo_dir}: install.py skipped")

        completed_nodes += 1
        remaining_nodes = total_nodes - completed_nodes
        print_success(
            f"{node_prefix} {node.repo_dir}: ready "
            f"({completed_nodes}/{total_nodes} complete, remaining {remaining_nodes})"
        )
        if on_progress:
            on_progress()
    return failures


def install_files(
    files: list[FileSpec],
    comfyui_dir: Path,
    *,
    hf_token: str | None,
    on_progress: callable | None = None,
) -> list[FileInstallFailure]:
    if not files:
        print_info("No files defined in install manifest; skipping file installation.")
        return []

    files_to_download: list[FileSpec] = []
    seen_targets: set[str] = set()
    for file_spec in files:
        normalized_target = Path(file_spec.target).as_posix()
        target_path = comfyui_dir / normalized_target
        if normalized_target in seen_targets:
            continue
        seen_targets.add(normalized_target)
        if not target_path.is_file():
            files_to_download.append(FileSpec(url=file_spec.url, target=normalized_target))

    if files_to_download:
        print_info("Checking available storage for pending downloads...")
        required_known_bytes = 0
        known_sizes_by_target: dict[str, int] = {}
        unknown_size_targets: list[str] = []
        for file_spec in files_to_download:
            size = probe_remote_file_size(file_spec.url, hf_token=hf_token)
            if size is None:
                unknown_size_targets.append(file_spec.target)
                continue
            known_sizes_by_target[file_spec.target] = size
            required_known_bytes += size

        free_bytes = effective_free_bytes(comfyui_dir)
        print_info(f"Storage preflight: known required={format_size_for_display(required_known_bytes)}")
        if required_known_bytes > free_bytes:
            raise RuntimeError(
                "Insufficient storage for downloads. "
                f"Need at least {format_size_for_display(required_known_bytes)} "
                f"but only {format_size_for_display(free_bytes)} is available."
            )
        if unknown_size_targets:
            print_warning(
                "Warning: could not determine remote size for "
                f"{len(unknown_size_targets)} file(s), so storage fit cannot be fully guaranteed."
            )
            for target in unknown_size_targets:
                print_warning(f" - {target}")
    else:
        known_sizes_by_target = {}

    progress_lock = Lock()
    reservation_lock = Lock()
    reserved_known_bytes = 0
    checkpoint_step = 10
    log_interval_seconds = 20.0
    checkpoint_state: dict[str, int] = {}
    last_log_time_by_target: dict[str, float] = {}

    def _process_file(file_spec: FileSpec) -> FileInstallFailure | None:
        nonlocal reserved_known_bytes
        target_path = comfyui_dir / file_spec.target
        if target_path.is_file():
            return None
        known_size = known_sizes_by_target.get(file_spec.target)
        reserved_size = 0
        try:
            if known_size is not None and known_size > 0:
                print_info(
                    f"[download] {file_spec.target}: started (0% 0/{format_size_for_display(known_size)})"
                )
            else:
                print_info(f"[download] {file_spec.target}: started (size unknown)")
            last_log_time_by_target[file_spec.target] = time.monotonic()

            if known_size is not None and known_size > 0:
                with reservation_lock:
                    free_bytes_now = effective_free_bytes(comfyui_dir)
                    available_bytes = free_bytes_now - reserved_known_bytes
                    if known_size > available_bytes:
                        raise RuntimeError(
                            "Insufficient storage before starting download. "
                            f"Need {format_size_for_display(known_size)} for {file_spec.target}, "
                            f"available now: {format_size_for_display(max(available_bytes, 0))}."
                        )
                    reserved_known_bytes += known_size
                    reserved_size = known_size

            last_progress_bytes = 0

            def _on_download_progress(downloaded: int, total_size: int | None) -> None:
                nonlocal last_progress_bytes
                with progress_lock:
                    now = time.monotonic()
                    delta = downloaded - last_progress_bytes
                    if delta > 0:
                        last_progress_bytes = downloaded
                    effective_total = known_size if known_size and known_size > 0 else total_size
                    total = effective_total if effective_total and effective_total > 0 else None
                    progress_snapshots[file_spec.target] = (downloaded, total)
                    if total is None:
                        last_log_time = last_log_time_by_target.get(file_spec.target, now)
                        if downloaded > 0 and now - last_log_time >= log_interval_seconds:
                            print_info(
                                f"[download] {file_spec.target}: progress "
                                f"({format_size_for_display(downloaded)} downloaded)"
                            )
                            last_log_time_by_target[file_spec.target] = now
                        return

                    percent = int((downloaded * 100) / total) if total > 0 else 0
                    last_checkpoint = checkpoint_state.get(file_spec.target, 0)
                    next_checkpoint = last_checkpoint + checkpoint_step
                    emitted_checkpoint = False
                    while next_checkpoint <= 90 and percent >= next_checkpoint:
                        print_info(
                            f"[download] {file_spec.target}: {next_checkpoint}% "
                            f"({format_size_for_display(downloaded)}/{format_size_for_display(total)})"
                        )
                        emitted_checkpoint = True
                        last_checkpoint = next_checkpoint
                        next_checkpoint += checkpoint_step
                    checkpoint_state[file_spec.target] = last_checkpoint
                    if emitted_checkpoint:
                        last_log_time_by_target[file_spec.target] = now
                        return

                    last_log_time = last_log_time_by_target.get(file_spec.target, now)
                    if downloaded > 0 and now - last_log_time >= log_interval_seconds:
                        print_info(
                            f"[download] {file_spec.target}: {percent}% "
                            f"({format_size_for_display(downloaded)}/{format_size_for_display(total)})"
                        )
                        last_log_time_by_target[file_spec.target] = now

            download_file(file_spec.url, target_path, hf_token=hf_token, on_progress=_on_download_progress)
        except Exception as exc:
            return FileInstallFailure(target=file_spec.target, error=str(exc))
        finally:
            if reserved_size > 0:
                with reservation_lock:
                    reserved_known_bytes = max(reserved_known_bytes - reserved_size, 0)
        return None

    failures: list[FileInstallFailure] = []
    progress_snapshots: dict[str, tuple[int, int | None]] = {}
    futures: dict = {}
    with ThreadPoolExecutor(max_workers=5) as executor:
        for file_spec in files_to_download:
            initial_total = known_sizes_by_target.get(file_spec.target)
            progress_snapshots[file_spec.target] = (0, initial_total if initial_total and initial_total > 0 else None)
            futures[executor.submit(_process_file, file_spec)] = file_spec

        total_downloads = len(futures)
        pending_targets = {file_spec.target for file_spec in files_to_download}
        completed_downloads = 0
        for future in as_completed(futures):
            file_spec = futures[future]
            pending_targets.discard(file_spec.target)
            completed_downloads += 1
            remaining_downloads = total_downloads - completed_downloads
            remaining_label = f"(remaining {remaining_downloads})"
            failure = future.result()
            if failure is not None:
                failures.append(failure)
                print_error(f"Failed to download {file_spec.target}: {failure.error}")
                print_info(f"Download progress: {remaining_label}")
            else:
                completed, total = progress_snapshots.get(file_spec.target, (0, None))
                if total and total > 0:
                    percent = int((completed * 100) / total) if total > 0 else 0
                    if completed < total:
                        print_warning(
                            f"[download] {file_spec.target}: Warning: incomplete download "
                            f"({format_size_for_display(completed)}/{format_size_for_display(total)})"
                        )
                    print_success(
                        f"[download] {file_spec.target}: {percent}% "
                        f"({format_size_for_display(completed)}/{format_size_for_display(total)}) completed {remaining_label}"
                    )
                else:
                    print_success(
                        f"[download] {file_spec.target}: completed "
                        f"({format_size_for_display(completed)}) {remaining_label}"
                    )
            if remaining_downloads == 1 and len(pending_targets) == 1:
                remaining_target = next(iter(pending_targets))
                print_info(f"Remaining download: {remaining_target} is downloading")
            if on_progress:
                on_progress()

    if failures:
        snapshot_table = Table(title="Failed Download Progress Snapshot")
        snapshot_table.add_column("Target", overflow="fold")
        snapshot_table.add_column("Progress", justify="right")
        for failure in failures:
            completed, total = progress_snapshots.get(failure.target, (0, None))
            if total and total > 0:
                progress_display = f"{format_size_for_display(completed)}/{format_size_for_display(total)}"
            else:
                progress_display = format_size_for_display(completed)
            snapshot_table.add_row(failure.target, progress_display)
        console().print(snapshot_table)

    # Keep deterministic failure ordering for summaries.
    failures.sort(key=lambda item: item.target)
    return failures


def remove_project_resources(node_dirs: list[str], file_targets: list[str], custom_nodes_dir: Path, comfyui_dir: Path) -> None:
    for repo_dir in node_dirs:
        node_path = custom_nodes_dir / repo_dir
        if node_path.is_dir():
            print_info(f"Removing old custom node: {repo_dir}")
            shutil.rmtree(node_path)

    for target in file_targets:
        file_path = comfyui_dir / target
        if file_path.is_file():
            print_info(f"Removing old file: {target}")
            file_path.unlink()


def print_custom_nodes_summary(title: str, specs: list[CustomNode], custom_nodes_dir: Path) -> None:
    print(title)
    if not specs:
        print(" - (none)")
        return
    for node in specs:
        suffix = "" if (custom_nodes_dir / node.repo_dir).is_dir() else " (missing on disk)"
        print(f" - {node.repo_dir}{suffix}")


def _group_key(target: str) -> str:
    parts = [part for part in Path(target).parts if part]
    if len(parts) <= 1:
        return "(root)"
    dir_parts = parts[:-1]
    if len(dir_parts) == 1:
        return dir_parts[0]
    return f"{dir_parts[0]}/{dir_parts[1]}"


def print_files_summary(title: str, specs: list[FileSpec], comfyui_dir: Path) -> None:
    print(title)
    if not specs:
        print(" - (none)")
        return

    groups: dict[str, list[tuple[str, bool]]] = {}
    for spec in specs:
        key = _group_key(spec.target)
        groups.setdefault(key, []).append((spec.target, (comfyui_dir / spec.target).is_file()))

    for key in sorted(groups):
        print(f" - {key}")
        for target, exists in groups[key]:
            suffix = "" if exists else " (missing on disk)"
            print(f"   - {target}{suffix}")
