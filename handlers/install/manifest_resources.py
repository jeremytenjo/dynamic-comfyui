#!/usr/bin/env python3

import argparse
import shlex
import sys
from pathlib import Path
from typing import Dict, List, Tuple

import yaml


def fail(message: str) -> None:
    print(f"❌ {message}", file=sys.stderr)
    raise SystemExit(1)


def load_yaml_mapping(path: Path, label: str) -> dict:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f"Failed to parse YAML for {label} ({path}): {exc}")
    if data is None:
        return {}
    if not isinstance(data, dict):
        fail(f"{label} root must be a mapping.")
    return data


def validate_target(value: str, label: str, idx: int) -> str:
    target_value = value.strip()
    target_path = Path(target_value)
    if target_path.is_absolute():
        fail(f"{label}[{idx}].target must be relative to ComfyUI root, got: {target_value}")
    if ".." in target_path.parts:
        fail(f"{label}[{idx}].target must not contain '..', got: {target_value}")
    if "\t" in target_value:
        fail(f"{label}[{idx}].target must not contain tabs")
    return target_value


def parse_custom_nodes(raw_custom_nodes, label: str) -> List[Tuple[str, str]]:
    if raw_custom_nodes is None:
        return []
    if not isinstance(raw_custom_nodes, list):
        fail(f"{label} must be a list")

    parsed: List[Tuple[str, str]] = []
    for idx, item in enumerate(raw_custom_nodes):
        if not isinstance(item, dict):
            fail(f"{label}[{idx}] must be a mapping")

        repo_dir = item.get("repo_dir")
        repo = item.get("repo")
        if not isinstance(repo_dir, str) or not repo_dir.strip():
            fail(f"{label}[{idx}] requires non-empty string field: repo_dir")
        if not isinstance(repo, str) or not repo.strip():
            fail(f"{label}[{idx}] requires non-empty string field: repo")

        repo_dir_value = repo_dir.strip()
        repo_value = repo.strip()
        if "\t" in repo_dir_value:
            fail(f"{label}[{idx}].repo_dir must not contain tabs")
        if "\t" in repo_value:
            fail(f"{label}[{idx}].repo must not contain tabs")

        parsed.append((repo_dir_value, repo_value))
    return parsed


def parse_custom_node_dirs_for_cleanup(raw_custom_nodes, label: str) -> List[str]:
    if raw_custom_nodes is None:
        return []
    if not isinstance(raw_custom_nodes, list):
        fail(f"{label} must be a list")

    parsed: List[str] = []
    for idx, item in enumerate(raw_custom_nodes):
        if not isinstance(item, dict):
            fail(f"{label}[{idx}] must be a mapping")

        repo_dir = item.get("repo_dir")
        if not isinstance(repo_dir, str) or not repo_dir.strip():
            fail(f"{label}[{idx}] requires non-empty string field: repo_dir")

        repo_dir_value = repo_dir.strip()
        if "\t" in repo_dir_value:
            fail(f"{label}[{idx}].repo_dir must not contain tabs")

        parsed.append(repo_dir_value)
    return parsed


def parse_url_target_list(raw_items, label: str) -> List[Tuple[str, str]]:
    if raw_items is None:
        return []
    if not isinstance(raw_items, list):
        fail(f"{label} must be a list")

    parsed: List[Tuple[str, str]] = []
    for idx, item in enumerate(raw_items):
        if not isinstance(item, dict):
            fail(f"{label}[{idx}] must be a mapping")

        url = item.get("url")
        target = item.get("target")
        if not isinstance(url, str) or not url.strip():
            fail(f"{label}[{idx}] requires non-empty string field: url")
        if not isinstance(target, str) or not target.strip():
            fail(f"{label}[{idx}] requires non-empty string field: target")

        url_value = url.strip()
        if "\t" in url_value:
            fail(f"{label}[{idx}].url must not contain tabs")
        target_value = validate_target(target, label, idx)

        parsed.append((url_value, target_value))
    return parsed


def write_merge_outputs(project_manifest_path: Path, default_manifest_path: Path, out_dir: Path) -> None:
    project_manifest = load_yaml_mapping(project_manifest_path, "Project manifest")
    default_manifest = {}
    if default_manifest_path and default_manifest_path.exists():
        if not default_manifest_path.is_file():
            fail(f"Default resources manifest path is not a file: {default_manifest_path}")
        default_manifest = load_yaml_mapping(default_manifest_path, "Default resources manifest")

    default_custom_nodes = parse_custom_nodes(default_manifest.get("custom_nodes"), "default custom_nodes")
    project_custom_nodes = parse_custom_nodes(project_manifest.get("custom_nodes"), "project custom_nodes")
    merged_custom_nodes_by_repo_dir: Dict[str, str] = {}
    for repo_dir, repo in default_custom_nodes:
        merged_custom_nodes_by_repo_dir[repo_dir] = repo
    for repo_dir, repo in project_custom_nodes:
        merged_custom_nodes_by_repo_dir[repo_dir] = repo

    default_models = parse_url_target_list(default_manifest.get("models"), "default models")
    project_models = parse_url_target_list(project_manifest.get("models"), "project models")
    merged_models_by_target: Dict[str, str] = {}
    for url, target in default_models:
        merged_models_by_target[target] = url
    for url, target in project_models:
        merged_models_by_target[target] = url

    default_files = parse_url_target_list(default_manifest.get("files"), "default files")
    project_files = parse_url_target_list(project_manifest.get("files"), "project files")
    merged_files_by_target: Dict[str, str] = {}
    for url, target in default_files:
        merged_files_by_target[target] = url
    for url, target in project_files:
        merged_files_by_target[target] = url

    custom_nodes_file = out_dir / "custom_nodes.tsv"
    models_file = out_dir / "models.tsv"
    files_file = out_dir / "files.tsv"
    default_custom_nodes_file = out_dir / "default_custom_nodes.tsv"
    project_custom_nodes_file = out_dir / "project_custom_nodes.tsv"
    default_models_file = out_dir / "default_models.tsv"
    project_models_file = out_dir / "project_models.tsv"
    default_files_file = out_dir / "default_files.tsv"
    project_files_file = out_dir / "project_files.tsv"

    with custom_nodes_file.open("w", encoding="utf-8") as nf:
        for repo_dir, repo in merged_custom_nodes_by_repo_dir.items():
            nf.write(f"{repo_dir}\t{repo}\n")

    with models_file.open("w", encoding="utf-8") as mf:
        for target, url in merged_models_by_target.items():
            mf.write(f"{url}\t{target}\n")

    with files_file.open("w", encoding="utf-8") as ff:
        for target, url in merged_files_by_target.items():
            ff.write(f"{url}\t{target}\n")

    with default_custom_nodes_file.open("w", encoding="utf-8") as nf:
        for repo_dir, repo in default_custom_nodes:
            nf.write(f"{repo_dir}\t{repo}\n")

    with project_custom_nodes_file.open("w", encoding="utf-8") as nf:
        for repo_dir, repo in project_custom_nodes:
            nf.write(f"{repo_dir}\t{repo}\n")

    with default_models_file.open("w", encoding="utf-8") as mf:
        for url, target in default_models:
            mf.write(f"{url}\t{target}\n")

    with project_models_file.open("w", encoding="utf-8") as mf:
        for url, target in project_models:
            mf.write(f"{url}\t{target}\n")

    with default_files_file.open("w", encoding="utf-8") as ff:
        for url, target in default_files:
            ff.write(f"{url}\t{target}\n")

    with project_files_file.open("w", encoding="utf-8") as ff:
        for url, target in project_files:
            ff.write(f"{url}\t{target}\n")

    print(f"export INSTALL_MANIFEST_CUSTOM_NODES_FILE={shlex.quote(str(custom_nodes_file))}")
    print(f"export INSTALL_MANIFEST_MODELS_FILE={shlex.quote(str(models_file))}")
    print(f"export INSTALL_MANIFEST_FILES_FILE={shlex.quote(str(files_file))}")
    print(f"export INSTALL_MANIFEST_DEFAULT_CUSTOM_NODES_FILE={shlex.quote(str(default_custom_nodes_file))}")
    print(f"export INSTALL_MANIFEST_PROJECT_CUSTOM_NODES_FILE={shlex.quote(str(project_custom_nodes_file))}")
    print(f"export INSTALL_MANIFEST_DEFAULT_MODELS_FILE={shlex.quote(str(default_models_file))}")
    print(f"export INSTALL_MANIFEST_PROJECT_MODELS_FILE={shlex.quote(str(project_models_file))}")
    print(f"export INSTALL_MANIFEST_DEFAULT_FILES_FILE={shlex.quote(str(default_files_file))}")
    print(f"export INSTALL_MANIFEST_PROJECT_FILES_FILE={shlex.quote(str(project_files_file))}")


def write_cleanup_outputs(manifest_path: Path, out_dir: Path) -> None:
    manifest = load_yaml_mapping(manifest_path, "Project manifest")
    custom_node_dirs = parse_custom_node_dirs_for_cleanup(manifest.get("custom_nodes"), "custom_nodes")
    models = parse_url_target_list(manifest.get("models"), "models")
    files = parse_url_target_list(manifest.get("files"), "files")

    custom_nodes_file = out_dir / "custom_nodes.tsv"
    models_file = out_dir / "models.tsv"
    files_file = out_dir / "files.tsv"

    with custom_nodes_file.open("w", encoding="utf-8") as nf:
        for repo_dir in custom_node_dirs:
            nf.write(f"{repo_dir}\n")

    with models_file.open("w", encoding="utf-8") as mf:
        for _url, target in models:
            mf.write(f"{target}\n")

    with files_file.open("w", encoding="utf-8") as ff:
        for _url, target in files:
            ff.write(f"{target}\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Parse and normalize ComfyUI resource manifests.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    merge_parser = subparsers.add_parser("merge")
    merge_parser.add_argument("--project-manifest", required=True)
    merge_parser.add_argument("--default-manifest", default="")
    merge_parser.add_argument("--out-dir", required=True)

    cleanup_parser = subparsers.add_parser("cleanup")
    cleanup_parser.add_argument("--manifest", required=True)
    cleanup_parser.add_argument("--out-dir", required=True)

    return parser.parse_args()


def main() -> None:
    args = parse_args()
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.command == "merge":
        write_merge_outputs(
            project_manifest_path=Path(args.project_manifest),
            default_manifest_path=Path(args.default_manifest.strip()) if args.default_manifest else Path(""),
            out_dir=out_dir,
        )
        return

    if args.command == "cleanup":
        write_cleanup_outputs(
            manifest_path=Path(args.manifest),
            out_dir=out_dir,
        )
        return

    fail(f"Unknown command: {args.command}")


if __name__ == "__main__":
    main()
