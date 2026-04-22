from __future__ import annotations

import shutil
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
import re
from threading import Lock

from rich.progress import BarColumn, DownloadColumn, Progress, TaskID, TextColumn, TimeElapsedColumn, TransferSpeedColumn

from .common import download_file, format_size_for_display, probe_remote_file_size, run
from .manifests import CustomNode, FileSpec


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
        print("No custom nodes defined in install manifest; skipping node installation.")
        return []

    failures: list[NodeInstallFailure] = []
    for idx, node in enumerate(custom_nodes, start=1):
        print(f"[{idx}/{len(custom_nodes)}] Ensuring git node {node.repo_dir}")
        node_path = custom_nodes_dir / node.repo_dir
        if node_path.is_dir():
            print(f"Custom node already installed, skipping: {node.repo_dir}")
            if on_progress:
                on_progress()
            continue

        if node_path.exists():
            shutil.rmtree(node_path)
        try:
            run(["git", "clone", node.repo, str(node_path)])
        except Exception as exc:
            failures.append(NodeInstallFailure(repo_dir=node.repo_dir, step="git clone", error=str(exc)))
            print(f"❌ Failed to clone custom node {node.repo_dir}: {exc}")
            if on_progress:
                on_progress()
            continue

        requirements = node_path / "requirements.txt"
        if requirements.is_file():
            try:
                run(["python3", "-m", "pip", "install", "--no-cache-dir", "-r", str(requirements)])
            except Exception as exc:
                failures.append(NodeInstallFailure(repo_dir=node.repo_dir, step="requirements install", error=str(exc)))
                print(f"❌ Failed to install requirements for {node.repo_dir}: {exc}")
                if on_progress:
                    on_progress()
                continue

        install_py = node_path / "install.py"
        if install_py.is_file():
            try:
                run(["python3", "install.py"], cwd=node_path)
            except Exception as exc:
                failures.append(NodeInstallFailure(repo_dir=node.repo_dir, step="install.py", error=str(exc)))
                print(f"❌ Failed to run install.py for {node.repo_dir}: {exc}")
                if on_progress:
                    on_progress()
                continue

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
        print("No files defined in install manifest; skipping file installation.")
        return []

    files_to_download: list[FileSpec] = []
    for file_spec in files:
        target_path = comfyui_dir / file_spec.target
        if not target_path.is_file():
            files_to_download.append(file_spec)

    if files_to_download:
        print("Checking available storage for pending downloads...")
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

        free_bytes = shutil.disk_usage(comfyui_dir).free
        print(
            "Storage preflight: "
            f"known required={format_size_for_display(required_known_bytes)}, "
            f"available={format_size_for_display(free_bytes)}"
        )
        if required_known_bytes > free_bytes:
            raise RuntimeError(
                "Insufficient storage for downloads. "
                f"Need at least {format_size_for_display(required_known_bytes)} "
                f"but only {format_size_for_display(free_bytes)} is available."
            )
        if unknown_size_targets:
            print(
                "Warning: could not determine remote size for "
                f"{len(unknown_size_targets)} file(s), so storage fit cannot be fully guaranteed."
            )
            for target in unknown_size_targets:
                print(f" - {target}")
    else:
        known_sizes_by_target = {}

    progress_lock = Lock()
    reservation_lock = Lock()
    reserved_known_bytes = 0
    url_pattern = re.compile(r"https?://\S+")

    def _colorize_urls_red(text: str) -> str:
        return url_pattern.sub(lambda m: f"\033[31m{m.group(0)}\033[0m", text)

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
                    free_bytes_now = shutil.disk_usage(comfyui_dir).free
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
    futures: dict = {}
    with Progress(
        TextColumn("{task.description}"),
        BarColumn(),
        DownloadColumn(),
        TransferSpeedColumn(),
        TimeElapsedColumn(),
        transient=True,
    ) as progress, ThreadPoolExecutor(max_workers=5) as executor:
        for idx, file_spec in enumerate(files, start=1):
            target_path = comfyui_dir / file_spec.target
            print(f"[{idx}/{len(files)}] Processing {file_spec.target}")
            if target_path.is_file():
                print(f"File already exists, skipping: {file_spec.target}")
                if on_progress:
                    on_progress()
                continue
            initial_total = known_sizes_by_target.get(file_spec.target)
            task_id = progress.add_task(
                f"Downloading {file_spec.target}",
                total=initial_total if initial_total and initial_total > 0 else None,
            )
            futures[executor.submit(_process_file, file_spec, progress, task_id)] = (file_spec, task_id)

        total_downloads = len(futures)
        completed_downloads = 0
        for future in as_completed(futures):
            file_spec, task_id = futures[future]
            completed_downloads += 1
            remaining_downloads = total_downloads - completed_downloads
            blue_remaining = f"\033[34m(remaining {remaining_downloads})\033[0m"
            failure = future.result()
            if failure is not None:
                failures.append(failure)
                progress.update(task_id, visible=False)
                print(f"❌ Failed to download {file_spec.target}: {_colorize_urls_red(failure.error)}")
                print(f"Download progress: {blue_remaining}")
            else:
                progress.update(task_id, visible=False)
                print(f"✅ Downloaded {file_spec.target} {blue_remaining}")
            if on_progress:
                on_progress()

    # Keep deterministic failure ordering for summaries.
    failures.sort(key=lambda item: item.target)
    return failures


def remove_project_resources(node_dirs: list[str], file_targets: list[str], custom_nodes_dir: Path, comfyui_dir: Path) -> None:
    for repo_dir in node_dirs:
        node_path = custom_nodes_dir / repo_dir
        if node_path.is_dir():
            print(f"Removing old custom node: {repo_dir}")
            shutil.rmtree(node_path)

    for target in file_targets:
        file_path = comfyui_dir / target
        if file_path.is_file():
            print(f"Removing old file: {target}")
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
