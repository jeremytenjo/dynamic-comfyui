from __future__ import annotations

import shutil
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from threading import Lock

from rich.progress import BarColumn, DownloadColumn, Progress, TaskID, TextColumn
from rich.table import Table

from .common import download_file, effective_free_bytes, format_size_for_display, probe_remote_file_size, run
from .manifests import CustomNode, FileSpec
from .ui import console, is_interactive_terminal, print_error, print_info, print_success, print_warning


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
    with Progress(
        TextColumn("{task.description}"),
        BarColumn(style="grey50", complete_style="blue", finished_style="blue", pulse_style="blue"),
        TextColumn("{task.completed:.0f}/{task.total:.0f}"),
        TextColumn("{task.fields[stage]}"),
        transient=is_interactive_terminal(),
    ) as progress:
        overall_task_id = progress.add_task("Custom nodes", total=len(custom_nodes), stage="starting")
        for node in custom_nodes:
            node_path = custom_nodes_dir / node.repo_dir
            node_task_id = progress.add_task(node.repo_dir, total=3, stage="queued")
            if node_path.is_dir():
                progress.update(node_task_id, completed=3, stage="already installed")
                progress.advance(overall_task_id, 1)
                progress.update(
                    overall_task_id,
                    stage=f"{int(progress.tasks[overall_task_id].completed)}/{len(custom_nodes)} complete",
                )
                if on_progress:
                    on_progress()
                continue

            if node_path.exists():
                shutil.rmtree(node_path)
            try:
                progress.update(node_task_id, stage="cloning")
                run(["git", "clone", node.repo, str(node_path)], quiet=True)
                progress.advance(node_task_id, 1, stage="clone complete")
            except Exception as exc:
                failures.append(NodeInstallFailure(repo_dir=node.repo_dir, step="git clone", error=str(exc)))
                print_error(f"Failed to clone custom node {node.repo_dir}: {exc}")
                progress.update(node_task_id, completed=3, stage="failed")
                progress.advance(overall_task_id, 1)
                progress.update(
                    overall_task_id,
                    stage=f"{int(progress.tasks[overall_task_id].completed)}/{len(custom_nodes)} complete",
                )
                if on_progress:
                    on_progress()
                continue

            requirements = node_path / "requirements.txt"
            if requirements.is_file():
                try:
                    progress.update(node_task_id, stage="installing requirements")
                    run(["python3", "-m", "pip", "install", "--no-cache-dir", "-r", str(requirements)], quiet=True)
                except Exception as exc:
                    failures.append(NodeInstallFailure(repo_dir=node.repo_dir, step="requirements install", error=str(exc)))
                    print_error(f"Failed to install requirements for {node.repo_dir}: {exc}")
                    progress.update(node_task_id, completed=3, stage="failed")
                    progress.advance(overall_task_id, 1)
                    progress.update(
                        overall_task_id,
                        stage=f"{int(progress.tasks[overall_task_id].completed)}/{len(custom_nodes)} complete",
                    )
                    if on_progress:
                        on_progress()
                    continue
                progress.advance(node_task_id, 1, stage="requirements complete")
            else:
                progress.advance(node_task_id, 1, stage="requirements skipped")

            install_py = node_path / "install.py"
            if install_py.is_file():
                try:
                    progress.update(node_task_id, stage="running install.py")
                    run(["python3", "install.py"], cwd=node_path, quiet=True)
                except Exception as exc:
                    failures.append(NodeInstallFailure(repo_dir=node.repo_dir, step="install.py", error=str(exc)))
                    print_error(f"Failed to run install.py for {node.repo_dir}: {exc}")
                    progress.update(node_task_id, completed=3, stage="failed")
                    progress.advance(overall_task_id, 1)
                    progress.update(
                        overall_task_id,
                        stage=f"{int(progress.tasks[overall_task_id].completed)}/{len(custom_nodes)} complete",
                    )
                    if on_progress:
                        on_progress()
                    continue
                progress.advance(node_task_id, 1, stage="install.py complete")
            else:
                progress.advance(node_task_id, 1, stage="install.py skipped")
            progress.update(node_task_id, stage="done")
            progress.advance(overall_task_id, 1)
            progress.update(
                overall_task_id,
                stage=f"{int(progress.tasks[overall_task_id].completed)}/{len(custom_nodes)} complete",
            )
            print_success(f"Custom node ready: {node.repo_dir}")
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
        target_path = comfyui_dir / file_spec.target
        if file_spec.target in seen_targets:
            continue
        seen_targets.add(file_spec.target)
        if not target_path.is_file():
            files_to_download.append(file_spec)

    if files_to_download:
        print_info("Checking available storage for pending downloads...")
        required_known_bytes = 0
        known_sizes_by_target: dict[str, int] = {}
        unknown_size_targets: list[str] = []
        preflight_rows: list[tuple[str, str, int | None]] = []
        for file_spec in files_to_download:
            size = probe_remote_file_size(file_spec.url, hf_token=hf_token)
            if size is None:
                unknown_size_targets.append(file_spec.target)
                preflight_rows.append((file_spec.target, "unknown", None))
                continue
            known_sizes_by_target[file_spec.target] = size
            required_known_bytes += size
            preflight_rows.append((file_spec.target, format_size_for_display(size), size))

        # Keep known sizes first, largest to smallest; unknown sizes are listed last.
        preflight_rows.sort(key=lambda row: (row[2] is None, -(row[2] or 0), row[0]))

        free_bytes = effective_free_bytes(comfyui_dir)
        print_info(f"Storage preflight: known required={format_size_for_display(required_known_bytes)}")
        preflight_table = Table(show_lines=False)
        preflight_table.add_column("Download Preflight", overflow="fold")
        preflight_table.add_column("Size", justify="right")
        for target, remote_size, _size_bytes in preflight_rows:
            preflight_table.add_row(target, remote_size)
        console().print(preflight_table)
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
    def _process_file(file_spec: FileSpec, progress: Progress, task_id: TaskID) -> FileInstallFailure | None:
        nonlocal reserved_known_bytes
        target_path = comfyui_dir / file_spec.target
        if target_path.is_file():
            return None
        known_size = known_sizes_by_target.get(file_spec.target)
        reserved_size = 0
        try:
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
                    total = total_size if total_size and total_size > 0 else None
                    if total is not None:
                        progress.update(task_id, total=total)
                    delta = downloaded - last_progress_bytes
                    if delta > 0:
                        progress.advance(task_id, delta)
                        last_progress_bytes = downloaded
                    progress_snapshots[file_spec.target] = (downloaded, total)

            download_file(file_spec.url, target_path, hf_token=hf_token, on_progress=_on_download_progress)
        except Exception as exc:
            return FileInstallFailure(target=file_spec.target, error=str(exc))
        finally:
            with progress_lock:
                progress.stop_task(task_id)
            if reserved_size > 0:
                with reservation_lock:
                    reserved_known_bytes = max(reserved_known_bytes - reserved_size, 0)
        return None

    failures: list[FileInstallFailure] = []
    progress_snapshots: dict[str, tuple[int, int | None]] = {}
    futures: dict = {}
    with Progress(
        TextColumn("{task.description}"),
        BarColumn(style="grey50", complete_style="blue", finished_style="blue", pulse_style="blue"),
        DownloadColumn(),
        transient=is_interactive_terminal(),
    ) as progress, ThreadPoolExecutor(max_workers=5) as executor:
        for file_spec in files_to_download:
            initial_total = known_sizes_by_target.get(file_spec.target)
            task_id = progress.add_task(
                f"Downloading {file_spec.target}",
                total=initial_total if initial_total and initial_total > 0 else None,
            )
            progress_snapshots[file_spec.target] = (0, initial_total if initial_total and initial_total > 0 else None)
            futures[executor.submit(_process_file, file_spec, progress, task_id)] = (file_spec, task_id)

        total_downloads = len(futures)
        completed_downloads = 0
        for future in as_completed(futures):
            file_spec, task_id = futures[future]
            completed_downloads += 1
            remaining_downloads = total_downloads - completed_downloads
            remaining_label = f"(remaining {remaining_downloads})"
            failure = future.result()
            if failure is not None:
                failures.append(failure)
                progress.update(task_id, visible=False)
                print_error(f"Failed to download {file_spec.target}: {failure.error}")
                print_info(f"Download progress: {remaining_label}")
            else:
                task = progress.tasks[task_id]
                progress_snapshots[file_spec.target] = (int(task.completed), int(task.total) if task.total else None)
                progress.update(task_id, visible=False)
                print_success(f"Downloaded {file_spec.target} {remaining_label}")
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
