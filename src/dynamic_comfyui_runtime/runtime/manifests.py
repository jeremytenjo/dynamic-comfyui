from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .common import download_file, ensure_dir, find_file_upwards, normalize_github_blob_url, read_json


@dataclass(frozen=True)
class CustomNode:
    repo_dir: str
    repo: str


@dataclass(frozen=True)
class FileSpec:
    url: str
    target: str


@dataclass(frozen=True)
class ManifestData:
    require_hf_token: bool
    custom_nodes: list[CustomNode]
    files: list[FileSpec]


@dataclass(frozen=True)
class MergedManifest:
    merged_custom_nodes: list[CustomNode]
    merged_files: list[FileSpec]
    default_custom_nodes: list[CustomNode]
    project_custom_nodes: list[CustomNode]
    default_files: list[FileSpec]
    project_files: list[FileSpec]


def active_project_manifest_path(network_volume: Path) -> Path:
    return network_volume / "projects" / "active-project.json"


def project_state_path(network_volume: Path) -> Path:
    return network_volume / ".dynamic-comfyui_selected_project"


def default_resources_url_from_package_json(package_json_path: Path) -> str:
    if not package_json_path.is_file():
        return ""
    data = read_json(package_json_path)
    value = data.get("default_resources_url", "")
    if not isinstance(value, str):
        raise ValueError("package.json field 'default_resources_url' must be a string")
    return normalize_github_blob_url(value.strip())


def _local_default_manifest_path(package_json_path: Path) -> Path | None:
    candidates: list[Path] = []
    package_candidate = package_json_path.parent / "default-resources.json"
    if package_candidate not in candidates:
        candidates.append(package_candidate)
    cwd_candidate = find_file_upwards("default-resources.json")
    if cwd_candidate is not None and cwd_candidate not in candidates:
        candidates.append(cwd_candidate)
    root_candidate = Path("/default-resources.json")
    if root_candidate not in candidates:
        candidates.append(root_candidate)
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def _parse_manifest(path: Path) -> ManifestData:
    data = read_json(path)
    require_value = data.get("require_huggingface_token", False)
    if not isinstance(require_value, bool):
        raise ValueError("Manifest field 'require_huggingface_token' must be a boolean")

    raw_nodes = data.get("custom_nodes", [])
    if raw_nodes is None:
        raw_nodes = []
    if not isinstance(raw_nodes, list):
        raise ValueError("Manifest field 'custom_nodes' must be a list")

    nodes: list[CustomNode] = []
    for idx, item in enumerate(raw_nodes):
        if not isinstance(item, dict):
            raise ValueError(f"custom_nodes[{idx}] must be an object")
        repo_dir = str(item.get("repo_dir", "")).strip()
        repo = str(item.get("repo", "")).strip()
        if not repo_dir or not repo:
            raise ValueError(f"custom_nodes[{idx}] requires 'repo_dir' and 'repo'")
        nodes.append(CustomNode(repo_dir=repo_dir, repo=repo))

    raw_files = data.get("files", [])
    if raw_files is None:
        raw_files = []
    if not isinstance(raw_files, list):
        raise ValueError("Manifest field 'files' must be a list")

    files: list[FileSpec] = []
    for idx, item in enumerate(raw_files):
        if not isinstance(item, dict):
            raise ValueError(f"files[{idx}] must be an object")
        url = str(item.get("url", "")).strip()
        target = str(item.get("target", "")).strip()
        if not url or not target:
            raise ValueError(f"files[{idx}] requires 'url' and 'target'")
        if target.startswith("/"):
            raise ValueError(f"files[{idx}].target must be relative to ComfyUI root")
        files.append(FileSpec(url=url, target=target))

    return ManifestData(require_hf_token=require_value, custom_nodes=nodes, files=files)


def write_empty_manifest(path: Path) -> None:
    ensure_dir(path.parent)
    path.write_text("{}\n", encoding="utf-8")


def save_project_state(network_volume: Path, key: str, manifest_path: Path, source_url: str) -> None:
    ensure_dir(network_volume)
    project_state_path(network_volume).write_text(
        f"{key}\t{manifest_path}\t{source_url}\n",
        encoding="utf-8",
    )


def load_project_state(network_volume: Path) -> tuple[str, Path, str]:
    state_path = project_state_path(network_volume)
    if not state_path.is_file():
        raise FileNotFoundError("No saved project selection found")
    lines = state_path.read_text(encoding="utf-8").splitlines()
    line = lines[0] if lines else ""
    parts = line.split("\t")
    if len(parts) < 2 or not parts[0].strip() or not parts[1].strip():
        raise RuntimeError(f"Saved project selection is invalid: {state_path}")
    key = parts[0].strip()
    manifest_path = Path(parts[1].strip())
    source_url = parts[2].strip() if len(parts) > 2 else ""
    return key, manifest_path, source_url


def normalize_manifest_url(url: str) -> str:
    return normalize_github_blob_url(url)


def validate_manifest_url(url: str) -> None:
    if not url.startswith(("http://", "https://")) or ".json" not in url:
        raise ValueError("Invalid JSON URL. Expected HTTP(S) URL ending in .json")


def download_manifest(url: str, path: Path) -> None:
    download_file(url, path)
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError(f"Downloaded project manifest is empty: {path}")


def resolve_default_manifest(package_json_path: Path, temp_dir: Path) -> Path:
    ensure_dir(temp_dir)
    default_url = default_resources_url_from_package_json(package_json_path)
    if default_url:
        candidate = temp_dir / "default-resources-remote.json"
        try:
            download_file(default_url, candidate)
            if candidate.is_file() and candidate.stat().st_size > 0:
                print(f"Loaded remote default resources manifest: {default_url}")
                return candidate
        except Exception as exc:
            print(f"Warning: failed to download remote default resources manifest: {default_url} ({exc})")
    local_manifest = _local_default_manifest_path(package_json_path)
    if local_manifest is not None:
        print(f"Loaded local default resources manifest: {local_manifest}")
        return local_manifest
    print("Warning: no default resources manifest available; continuing with project resources only.")
    empty = temp_dir / "default-resources-empty.json"
    empty.write_text('{"custom_nodes": [], "files": []}\n', encoding="utf-8")
    return empty


def merge_manifests(project_manifest_path: Path, default_manifest_path: Path) -> MergedManifest:
    project = _parse_manifest(project_manifest_path)
    default = _parse_manifest(default_manifest_path)

    merged_nodes_map: dict[str, CustomNode] = {}
    for node in default.custom_nodes:
        merged_nodes_map[node.repo_dir] = node
    for node in project.custom_nodes:
        merged_nodes_map[node.repo_dir] = node

    merged_files_map: dict[str, FileSpec] = {}
    for file_spec in default.files:
        merged_files_map[file_spec.target] = file_spec
    for file_spec in project.files:
        merged_files_map[file_spec.target] = file_spec

    return MergedManifest(
        merged_custom_nodes=list(merged_nodes_map.values()),
        merged_files=list(merged_files_map.values()),
        default_custom_nodes=default.custom_nodes,
        project_custom_nodes=project.custom_nodes,
        default_files=default.files,
        project_files=project.files,
    )


def project_requires_hf_token(project_manifest_path: Path) -> bool:
    return _parse_manifest(project_manifest_path).require_hf_token


def resources_for_cleanup(project_manifest_path: Path) -> tuple[list[str], list[str]]:
    data = _parse_manifest(project_manifest_path)
    node_dirs = [node.repo_dir for node in data.custom_nodes]
    file_targets = [file_spec.target for file_spec in data.files]
    return node_dirs, file_targets
