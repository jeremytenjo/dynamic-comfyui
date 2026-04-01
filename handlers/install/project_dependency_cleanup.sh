# shellcheck shell=bash


remove_dependencies_from_manifest() {
    local manifest_path="$1"

    if [ -z "$manifest_path" ] || [ ! -f "$manifest_path" ]; then
        echo "❌ Cannot remove dependencies. Manifest not found: $manifest_path"
        return 1
    fi

    local cleanup_tmp_dir
    cleanup_tmp_dir="$(mktemp -d /tmp/avatary-project-cleanup.XXXXXX)"

    local parse_rc=0
    if python3 - "$manifest_path" "$cleanup_tmp_dir" <<'PY'
import sys
from pathlib import Path

import yaml


def fail(message: str) -> None:
    print(f"❌ {message}", file=sys.stderr)
    raise SystemExit(1)


if len(sys.argv) != 3:
    fail("Internal error: expected manifest path and output directory arguments")

manifest_path = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
out_dir.mkdir(parents=True, exist_ok=True)

try:
    data = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
except Exception as exc:
    fail(f"Failed to parse YAML manifest {manifest_path}: {exc}")

if not isinstance(data, dict):
    fail("Manifest root must be a mapping")

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

        repo_dir = item.get("repo_dir")
        if not isinstance(repo_dir, str) or not repo_dir.strip():
            fail(f"custom_nodes[{idx}] requires non-empty string field: repo_dir")

        repo_dir = repo_dir.strip()
        if "\t" in repo_dir:
            fail(f"custom_nodes[{idx}].repo_dir must not contain tabs")

        nf.write(f"{repo_dir}\n")

with models_file.open("w", encoding="utf-8") as mf:
    for idx, item in enumerate(models):
        if not isinstance(item, dict):
            fail(f"models[{idx}] must be a mapping")

        target = item.get("target")
        if not isinstance(target, str) or not target.strip():
            fail(f"models[{idx}] requires non-empty string field: target")

        target = target.strip()
        target_path = Path(target)
        if target_path.is_absolute():
            fail(f"models[{idx}].target must be relative to ComfyUI root, got: {target}")
        if ".." in target_path.parts:
            fail(f"models[{idx}].target must not contain '..', got: {target}")
        if "\t" in target:
            fail(f"models[{idx}].target must not contain tabs")

        mf.write(f"{target}\n")
PY
    else
        parse_rc=$?
    fi

    if [ "$parse_rc" -ne 0 ]; then
        rm -rf "$cleanup_tmp_dir"
        return 1
    fi

    local nodes_file="$cleanup_tmp_dir/custom_nodes.tsv"
    local models_file="$cleanup_tmp_dir/models.tsv"

    if [ -f "$nodes_file" ]; then
        local repo_dir
        while IFS= read -r repo_dir; do
            [ -n "$repo_dir" ] || continue
            local node_path="$CUSTOM_NODES_DIR/$repo_dir"
            if [ -d "$node_path" ]; then
                echo "Removing old custom node: $repo_dir"
                rm -rf "$node_path"
            fi
        done < "$nodes_file"
    fi

    if [ -f "$models_file" ]; then
        local model_target
        while IFS= read -r model_target; do
            [ -n "$model_target" ] || continue
            local model_path="$COMFYUI_DIR/$model_target"
            if [ -f "$model_path" ]; then
                echo "Removing old model: $model_target"
                rm -f "$model_path"
            fi
        done < "$models_file"
    fi

    rm -rf "$cleanup_tmp_dir"
    return 0
}
