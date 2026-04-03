# shellcheck shell=bash


download_file_with_curl() {
    local url="$1"
    local full_path="$2"
    local target_rel="$3"

    if [ -f "$full_path" ]; then
        echo "✅ File already exists, skipping: $target_rel"
        return 0
    fi

    echo "⬇️ Downloading file: $target_rel"
    if ! curl_download_to_file "$url" "$full_path"; then
        echo "❌ Failed to download file target: $target_rel"
        return 1
    fi

    return 0
}


install_files() {
    if [ -z "${INSTALL_MANIFEST_FILES_FILE:-}" ] || [ ! -f "$INSTALL_MANIFEST_FILES_FILE" ]; then
        echo "❌ Manifest file data is missing. Ensure load_install_manifest ran successfully."
        return 1
    fi

    local -a file_specs=()
    if ! read_nonempty_lines "$INSTALL_MANIFEST_FILES_FILE"; then
        echo "❌ Failed to read file install manifest entries: $INSTALL_MANIFEST_FILES_FILE"
        return 1
    fi
    if [ "${READ_NONEMPTY_LINES_COUNT:-0}" -gt 0 ]; then
        file_specs=("${READ_NONEMPTY_LINES[@]}")
    fi

    if [ "${#file_specs[@]}" -eq 0 ]; then
        echo "No files defined in install manifest; skipping file installation."
        return 0
    fi

    local total_files=${#file_specs[@]}
    local file_idx=0
    local failed_downloads=0
    local refresh_progress=0
    if declare -F setup_progress_refresh >/dev/null 2>&1; then
        refresh_progress=1
    fi
    local file_spec
    for file_spec in "${file_specs[@]}"; do
        local file_url
        local file_target
        local file_path
        IFS=$'\t' read -r file_url file_target <<< "$file_spec"
        file_path="$COMFYUI_DIR/$file_target"
        file_idx=$((file_idx + 1))
        echo "📁 [$file_idx/$total_files] Processing $file_target"

        if ! download_file_with_curl "$file_url" "$file_path" "$file_target"; then
            failed_downloads=$((failed_downloads + 1))
        fi

        if [ "$refresh_progress" -eq 1 ]; then
            setup_progress_refresh || true
        fi
    done

    if [ "$failed_downloads" -gt 0 ]; then
        echo "❌ $failed_downloads file download task(s) failed."
        return 1
    fi

    return 0
}


print_installed_files_summary() {
    print_installed_files_summary_from_file "Installed files (default resources):" "${INSTALL_MANIFEST_DEFAULT_FILES_FILE:-}"
    print_installed_files_summary_from_file "Installed files (project manifest):" "${INSTALL_MANIFEST_PROJECT_FILES_FILE:-}"
    return 0
}


print_installed_files_summary_from_file() {
    local title="$1"
    local manifest_file="$2"

    echo "$title"
    if [ -z "$manifest_file" ] || [ ! -f "$manifest_file" ]; then
        echo " - (unavailable)"
        return 0
    fi

    if ! read_nonempty_lines "$manifest_file"; then
        echo " - (failed to read)"
        return 0
    fi
    if [ "${READ_NONEMPTY_LINES_COUNT:-0}" -eq 0 ]; then
        echo " - (none)"
        return 0
    fi

    if ! python3 - "$manifest_file" "${COMFYUI_DIR:-/workspace/ComfyUI}" <<'PY'
import sys
from collections import defaultdict
from pathlib import Path


def group_key(target: str) -> str:
    parts = [part for part in Path(target).parts if part]
    if len(parts) <= 1:
        return "(root)"
    dir_parts = parts[:-1]
    if len(dir_parts) == 1:
        return dir_parts[0]
    return f"{dir_parts[0]}/{dir_parts[1]}"


manifest_file = Path(sys.argv[1])
comfyui_dir = Path(sys.argv[2])
groups: dict[str, list[tuple[str, bool]]] = defaultdict(list)

for raw in manifest_file.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line:
        continue
    parts = line.split("\t", 1)
    if len(parts) != 2:
        continue
    _url, target = parts
    target = target.strip()
    if not target:
        continue
    exists = (comfyui_dir / target).is_file()
    groups[group_key(target)].append((target, exists))

for key in sorted(groups):
    print(f" - {key}")
    for target, exists in groups[key]:
        suffix = "" if exists else " (missing on disk)"
        print(f"   - {target}{suffix}")
PY
    then
        echo " - (failed to summarize)"
    fi

    return 0
}
