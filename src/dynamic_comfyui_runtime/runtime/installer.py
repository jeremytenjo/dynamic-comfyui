from __future__ import annotations

import shutil
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

from .common import download_file, run
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

    def _process_file(file_spec: FileSpec) -> FileInstallFailure | None:
        target_path = comfyui_dir / file_spec.target
        if target_path.is_file():
            return None
        try:
            download_file(file_spec.url, target_path, hf_token=hf_token)
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

        for future in as_completed(futures):
            file_spec = futures[future]
            failure = future.result()
            if failure is not None:
                failures.append(failure)
                print(f"❌ Failed to download {file_spec.target}: {failure.error}")
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
