# shellcheck shell=bash


setup_page_dir_path() {
    printf '%s\n' "/tmp/dynamic-comfyui-setup-page"
}


setup_progress_file_path() {
    printf '%s/progress.json\n' "$(setup_page_dir_path)"
}


write_setup_progress_json() {
    local status="$1"
    local message="${2:-}"
    local progress_file
    progress_file="$(setup_progress_file_path)"
    local setup_dir
    setup_dir="$(setup_page_dir_path)"

    mkdir -p "$setup_dir"

    local models_file="${INSTALL_MANIFEST_MODELS_FILE:-}"
    local files_file="${INSTALL_MANIFEST_FILES_FILE:-}"
    local comfyui_dir="${COMFYUI_DIR:-/workspace/ComfyUI}"

    if ! python3 - "$progress_file" "$status" "$message" "$comfyui_dir" "$models_file" "$files_file" <<'PY'
import json
import os
import sys
from pathlib import Path


def read_targets(tsv_path: str, kind: str) -> list[dict]:
    items = []
    if not tsv_path:
        return items
    path = Path(tsv_path)
    if not path.is_file():
        return items

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        _url, target = parts
        items.append({"target": target, "kind": kind})
    return items


if len(sys.argv) != 7:
    raise SystemExit(1)

progress_file = Path(sys.argv[1])
status = sys.argv[2]
message = sys.argv[3]
comfyui_dir = Path(sys.argv[4])
models_tsv = sys.argv[5]
files_tsv = sys.argv[6]

items = read_targets(models_tsv, "model") + read_targets(files_tsv, "file")
for item in items:
    item_path = comfyui_dir / item["target"]
    item["checked"] = item_path.is_file()

payload = {
    "status": status,
    "message": message,
    "updated_at": int(__import__("time").time()),
    "items": items,
}

progress_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
    then
        echo "⚠️ Failed to update setup progress file: $progress_file"
        return 1
    fi

    return 0
}


setup_progress_init() {
    write_setup_progress_json "running" "Installing resources..."
}


setup_progress_refresh() {
    write_setup_progress_json "running" "Installing resources..."
}


setup_progress_mark_done() {
    write_setup_progress_json "done" "Installation complete."
}


setup_progress_mark_failed() {
    local message="${1:-Installation failed. Check terminal logs.}"
    write_setup_progress_json "failed" "$message"
}


setup_progress_mark_idle() {
    write_setup_progress_json "idle" "Waiting for installation to start."
}
