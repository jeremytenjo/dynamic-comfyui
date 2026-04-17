from __future__ import annotations

import tempfile
from dataclasses import dataclass
from pathlib import Path

from .common import download_file, ensure_dir, find_file_upwards, normalize_github_blob_url, read_json


DEFAULT_RESOURCES_URL = normalize_github_blob_url(
    "https://github.com/jeremytenjo/dynamic-comfyui/blob/main/default-resources.json"
)


@dataclass(frozen=True)
class CustomNode:
    repo_dir: str
    repo: str


@dataclass(frozen=True)
class FileSpec:
    url: str
    target: str


@dataclass(frozen=True)
class ImportProject:
    project_url: str


@dataclass(frozen=True)
class ManifestData:
    require_hf_token: bool
    custom_nodes: list[CustomNode]
    files: list[FileSpec]
    import_projects: list[ImportProject]


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
    # Defaults are intentionally pinned to a canonical remote manifest URL so
    # pip-installed runtime wheels behave the same even when package.json is absent.
    _ = package_json_path
    return DEFAULT_RESOURCES_URL


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

    raw_imports = data.get("import_projects", [])
    if raw_imports is None:
        raw_imports = []
    if not isinstance(raw_imports, list):
        raise ValueError("Manifest field 'import_projects' must be a list")

    import_projects: list[ImportProject] = []
    for idx, item in enumerate(raw_imports):
        if not isinstance(item, dict):
            raise ValueError(f"import_projects[{idx}] must be an object")
        keys = set(item.keys())
        if keys != {"project_url"}:
            raise ValueError(f"import_projects[{idx}] must only contain 'project_url'")
        project_url = normalize_manifest_url(str(item.get("project_url", "")).strip())
        if not project_url:
            raise ValueError(f"import_projects[{idx}].project_url is required")
        try:
            validate_manifest_url(project_url)
        except Exception as exc:
            red_project_url = f"\033[31m'{project_url}'\033[0m"
            print(f"⚠️ Warning: skipping invalid import_projects[{idx}].project_url {red_project_url} ({exc})")
            continue
        import_projects.append(ImportProject(project_url=project_url))

    return ManifestData(
        require_hf_token=require_value,
        custom_nodes=nodes,
        files=files,
        import_projects=import_projects,
    )


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
                blue_default_url = f"\033[34m{default_url}\033[0m"
                print(f"Loaded remote default resources manifest: {blue_default_url}")
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


def _resolve_imported_manifests(root: ManifestData, temp_dir: Path) -> list[ManifestData]:
    ensure_dir(temp_dir)
    visited: set[str] = set()
    visiting: set[str] = set()

    def _resolve(url: str) -> list[ManifestData]:
        normalized = normalize_manifest_url(url)
        if normalized in visiting:
            print(f"Warning: skipping cyclic imported project manifest: {normalized}")
            return []
        if normalized in visited:
            return []

        visiting.add(normalized)
        candidate = temp_dir / f"import-project-{len(visited) + len(visiting)}.json"
        try:
            download_manifest(normalized, candidate)
            parsed = _parse_manifest(candidate)
        except Exception as exc:
            print(f"Warning: failed to import project manifest {normalized} ({exc})")
            visiting.remove(normalized)
            return []

        merged: list[ManifestData] = []
        for nested in parsed.import_projects:
            merged.extend(_resolve(nested.project_url))
        merged.append(parsed)
        visiting.remove(normalized)
        visited.add(normalized)
        return merged

    resolved: list[ManifestData] = []
    for import_project in root.import_projects:
        resolved.extend(_resolve(import_project.project_url))
    return resolved


def _resolved_project_manifest(project_manifest_path: Path, temp_dir: Path) -> ManifestData:
    root = _parse_manifest(project_manifest_path)
    imported = _resolve_imported_manifests(root, temp_dir)

    merged_nodes_map: dict[str, CustomNode] = {}
    merged_files_map: dict[str, FileSpec] = {}
    require_hf_token = root.require_hf_token

    for manifest in imported:
        require_hf_token = require_hf_token or manifest.require_hf_token
        for node in manifest.custom_nodes:
            merged_nodes_map[node.repo_dir] = node
        for file_spec in manifest.files:
            merged_files_map[file_spec.target] = file_spec

    for node in root.custom_nodes:
        merged_nodes_map[node.repo_dir] = node
    for file_spec in root.files:
        merged_files_map[file_spec.target] = file_spec

    return ManifestData(
        require_hf_token=require_hf_token,
        custom_nodes=list(merged_nodes_map.values()),
        files=list(merged_files_map.values()),
        import_projects=root.import_projects,
    )


def merge_manifests(project_manifest_path: Path, default_manifest_path: Path, *, temp_dir: Path | None = None) -> MergedManifest:
    resolved_temp_dir = temp_dir or Path(tempfile.mkdtemp(prefix="dynamic-comfyui-import-projects-"))
    project = _resolved_project_manifest(project_manifest_path, resolved_temp_dir)
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
    temp_dir = Path(tempfile.mkdtemp(prefix="dynamic-comfyui-import-projects-"))
    return _resolved_project_manifest(project_manifest_path, temp_dir).require_hf_token


def resources_for_cleanup(project_manifest_path: Path) -> tuple[list[str], list[str]]:
    temp_dir = Path(tempfile.mkdtemp(prefix="dynamic-comfyui-import-projects-"))
    data = _resolved_project_manifest(project_manifest_path, temp_dir)
    node_dirs = [node.repo_dir for node in data.custom_nodes]
    file_targets = [file_spec.target for file_spec in data.files]
    return node_dirs, file_targets
