# shellcheck shell=bash


install_custom_nodes() {
    if [ -z "${INSTALL_MANIFEST_CUSTOM_NODES_FILE:-}" ] || [ ! -f "$INSTALL_MANIFEST_CUSTOM_NODES_FILE" ]; then
        echo "❌ Manifest custom node data is missing. Ensure load_install_manifest ran successfully."
        return 1
    fi

    if ! ensure_comfy_cli_ready; then
        return 1
    fi

    if ! cd "$COMFYUI_DIR"; then
        echo "❌ Failed to cd into ComfyUI workspace: $COMFYUI_DIR"
        return 1
    fi

    local snapshot_path
    snapshot_path="$(install_manifest_tmp_dir)/custom-nodes-snapshot.json"

    if ! python3 - "$INSTALL_MANIFEST_CUSTOM_NODES_FILE" "$snapshot_path" <<'PY'
import json
import sys


def fail(msg: str) -> None:
    print(f"❌ {msg}", file=sys.stderr)
    raise SystemExit(1)


if len(sys.argv) != 3:
    fail("Internal error: expected manifest node TSV and snapshot path.")

manifest_nodes_tsv = sys.argv[1]
snapshot_path = sys.argv[2]

cnr_custom_nodes = {}
git_custom_nodes = {}

with open(manifest_nodes_tsv, encoding="utf-8") as f:
    for line_no, raw_line in enumerate(f, start=1):
        line = raw_line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 5:
            fail(f"Invalid node entry format at line {line_no}.")

        cnr_id, _repo_dir, repo_url, pin_type, pin_value = parts

        # Snapshot restore supports exact CNR version switching by ID.
        if cnr_id and pin_type == "tag":
            cnr_custom_nodes[cnr_id] = pin_value
            continue

        # For non-CNR or commit-pinned entries, let restore-snapshot install from git URL.
        # Empty hash means clone/update without forcing a checkout hash.
        git_hash = pin_value if pin_type == "commit" else ""
        git_custom_nodes[repo_url] = {"hash": git_hash, "disabled": False}

snapshot = {
    "comfyui": None,
    "git_custom_nodes": git_custom_nodes,
    "cnr_custom_nodes": cnr_custom_nodes,
    "file_custom_nodes": [],
    "pips": {},
}

with open(snapshot_path, "w", encoding="utf-8") as out:
    json.dump(snapshot, out, indent=2)
PY
    then
        return 1
    fi

    local cnr_count
    local git_count
    cnr_count="$(python3 - "$snapshot_path" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(len(data.get("cnr_custom_nodes", {})))
PY
)"
    git_count="$(python3 - "$snapshot_path" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(len(data.get("git_custom_nodes", {})))
PY
)"

    echo "Restoring node snapshot from manifest (cnr: $cnr_count, git: $git_count)..."
    if ! comfy --workspace="$COMFYUI_DIR" node restore-snapshot "$snapshot_path"; then
        echo "❌ Failed to restore node snapshot."
        return 1
    fi

    return 0
}
