# shellcheck shell=bash


load_install_manifest() {
    if [ -z "${INSTALL_MANIFEST_PATH:-}" ]; then
        echo "❌ INSTALL_MANIFEST_PATH is not set."
        return 1
    fi

    if [ ! -f "$INSTALL_MANIFEST_PATH" ]; then
        echo "❌ Install manifest not found: $INSTALL_MANIFEST_PATH"
        return 1
    fi

    local manifest_tmp_dir="/tmp/avatary-install-manifest"
    rm -rf "$manifest_tmp_dir"
    mkdir -p "$manifest_tmp_dir"

    local exports_output
    if ! exports_output="$(
        python3 - "$INSTALL_MANIFEST_PATH" "$manifest_tmp_dir" <<'PY'
import re
import shlex
import sys
from pathlib import Path

import yaml


def fail(msg: str) -> None:
    print(f"❌ {msg}", file=sys.stderr)
    raise SystemExit(1)


if len(sys.argv) != 3:
    fail("Internal error: expected manifest path and output directory arguments.")

manifest_path = Path(sys.argv[1])
out_dir = Path(sys.argv[2])

try:
    data = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
except Exception as exc:
    fail(f"Failed to parse YAML manifest {manifest_path}: {exc}")

if not isinstance(data, dict):
    fail("Manifest root must be a mapping.")

version = data.get("comfyui_version")
if not isinstance(version, str) or not version.strip():
    fail("Manifest requires non-empty string field: comfyui_version")
version = version.strip()
if not re.match(r"^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$", version):
    fail("comfyui_version must be semver (example: 0.3.39 or v0.3.39)")

custom_nodes = data.get("custom_nodes")
if custom_nodes is None:
    custom_nodes = []
if not isinstance(custom_nodes, list):
    fail("custom_nodes must be a list")

models = data.get("models")
if models is None:
    models = []
if not isinstance(models, list):
    fail("models must be a list")

nodes_file = out_dir / "custom_nodes.tsv"
models_file = out_dir / "models.tsv"

with nodes_file.open("w", encoding="utf-8") as nf:
    for idx, item in enumerate(custom_nodes):
        if not isinstance(item, dict):
            fail(f"custom_nodes[{idx}] must be a mapping")

        cnr_id = item.get("cnr_id", "")
        repo_dir = item.get("repo_dir")
        repo = item.get("repo")
        tag = item.get("tag")
        commit = item.get("commit")

        if cnr_id is None:
            cnr_id = ""
        if not isinstance(cnr_id, str):
            fail(f"custom_nodes[{idx}].cnr_id must be a string when provided")
        if not isinstance(repo_dir, str) or not repo_dir.strip():
            fail(f"custom_nodes[{idx}] requires non-empty string field: repo_dir")
        if not isinstance(repo, str) or not repo.strip():
            fail(f"custom_nodes[{idx}] requires non-empty string field: repo")

        has_tag = isinstance(tag, str) and bool(tag.strip())
        has_commit = isinstance(commit, str) and bool(commit.strip())
        if has_tag == has_commit:
            fail(f"custom_nodes[{idx}] must define exactly one of tag or commit")

        pin_type = "tag" if has_tag else "commit"
        pin_value = tag.strip() if has_tag else commit.strip()
        if "\t" in pin_value:
            fail(f"custom_nodes[{idx}] pin value must not contain tabs")
        if "\t" in repo_dir or "\t" in repo or "\t" in cnr_id:
            fail(f"custom_nodes[{idx}] fields must not contain tabs")

        nf.write(f"{cnr_id}\t{repo_dir.strip()}\t{repo.strip()}\t{pin_type}\t{pin_value}\n")

with models_file.open("w", encoding="utf-8") as mf:
    for idx, item in enumerate(models):
        if not isinstance(item, dict):
            fail(f"models[{idx}] must be a mapping")

        url = item.get("url")
        target = item.get("target")
        if not isinstance(url, str) or not url.strip():
            fail(f"models[{idx}] requires non-empty string field: url")
        if not isinstance(target, str) or not target.strip():
            fail(f"models[{idx}] requires non-empty string field: target")

        target_value = target.strip()
        target_path = Path(target_value)
        if target_path.is_absolute():
            fail(f"models[{idx}].target must be relative to ComfyUI root, got: {target_value}")
        if ".." in target_path.parts:
            fail(f"models[{idx}].target must not contain '..', got: {target_value}")

        if "\t" in url or "\t" in target_value:
            fail(f"models[{idx}] fields must not contain tabs")

        mf.write(f"{url.strip()}\t{target_value}\n")

print(f"export COMFYUI_VERSION={shlex.quote(version)}")
print(f"export INSTALL_MANIFEST_CUSTOM_NODES_FILE={shlex.quote(str(nodes_file))}")
print(f"export INSTALL_MANIFEST_MODELS_FILE={shlex.quote(str(models_file))}")
PY
    )"; then
        return 1
    fi

    eval "$exports_output"

    if [ ! -f "$INSTALL_MANIFEST_CUSTOM_NODES_FILE" ] || [ ! -f "$INSTALL_MANIFEST_MODELS_FILE" ]; then
        echo "❌ Manifest loader failed to generate normalized data files."
        return 1
    fi

    echo "Loaded install manifest: $INSTALL_MANIFEST_PATH"
    echo "ComfyUI version from manifest: $COMFYUI_VERSION"
    return 0
}
