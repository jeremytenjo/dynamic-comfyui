from __future__ import annotations

import shutil
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from threading import Lock

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
        unknown_size_targets: list[str] = []
        for file_spec in files_to_download:
            size = probe_remote_file_size(file_spec.url, hf_token=hf_token)
            if size is None:
                unknown_size_targets.append(file_spec.target)
                continue
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

    progress_lock = Lock()

    def _process_file(file_spec: FileSpec) -> FileInstallFailure | None:
        target_path = comfyui_dir / file_spec.target
        if target_path.is_file():
            return None
        try:
            last_percent_bucket = -1
            last_unknown_report_mb = -1
            last_reported_bytes = 0
            last_report_ts = time.monotonic()

            def _on_download_progress(downloaded: int, total_size: int | None) -> None:
                nonlocal last_percent_bucket, last_unknown_report_mb, last_reported_bytes, last_report_ts
                with progress_lock:
                    if total_size and total_size > 0:
                        percent = int((downloaded * 100) / total_size)
                        bucket = min(percent // 10, 10)
                        now = time.monotonic()
                        progressed_bytes = downloaded - last_reported_bytes
                        should_print = False
                        if bucket > last_percent_bucket:
                            last_percent_bucket = bucket
                            should_print = True
                        elif progressed_bytes >= 256 * 1024 * 1024:
                            should_print = True
                        elif progressed_bytes > 0 and (now - last_report_ts) >= 20:
                            should_print = True
                        if not should_print:
                            return
                        print(
                            f"  Downloading {file_spec.target}: {percent}% "
                            f"({format_size_for_display(downloaded)}/{format_size_for_display(total_size)})"
                        )
                        last_reported_bytes = downloaded
                        last_report_ts = now
                        return

                    downloaded_mb = downloaded // (1024 * 1024)
                    report_bucket = downloaded_mb // 25
                    if report_bucket <= last_unknown_report_mb:
                        return
                    last_unknown_report_mb = report_bucket
                    print(f"  Downloading {file_spec.target}: {format_size_for_display(downloaded)}")

            download_file(file_spec.url, target_path, hf_token=hf_token, on_progress=_on_download_progress)
        except Exception as exc:
            return FileInstallFailure(target=file_spec.target, error=str(exc))
        return None

    failures: list[FileInstallFailure] = []
    futures = {}
    with ThreadPoolExecutor(max_workers=5) as executor:
        for idx, file_spec in enumerate(files, start=1):
            target_path = comfyui_dir / file_spec.target
            print(f"[{idx}/{len(files)}] Processing {file_spec.target}")
            if target_path.is_file():
                print(f"File already exists, skipping: {file_spec.target}")
                if on_progress:
                    on_progress()
                continue
            futures[executor.submit(_process_file, file_spec)] = file_spec

        total_downloads = len(futures)
        completed_downloads = 0
        for future in as_completed(futures):
            file_spec = futures[future]
            completed_downloads += 1
            remaining_downloads = total_downloads - completed_downloads
            failure = future.result()
            if failure is not None:
                failures.append(failure)
                print(f"❌ Failed to download {file_spec.target}: {failure.error}")
                print(
                    f"Download progress: completed {completed_downloads}/{total_downloads}, "
                    f"remaining {remaining_downloads}"
                )
            else:
                print(
                    f"✅ Downloaded {file_spec.target} "
                    f"(completed {completed_downloads}/{total_downloads}, remaining {remaining_downloads})"
                )
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
