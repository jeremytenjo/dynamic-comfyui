# shellcheck shell=bash


default_resources_config_path() {
    if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/package.json" ]; then
        printf '%s\n' "$SCRIPT_DIR/package.json"
        return 0
    fi
    if [ -f "/package.json" ]; then
        printf '%s\n' "/package.json"
        return 0
    fi
    printf '%s\n' ""
    return 0
}


read_default_resources_url_from_config() {
    local config_path="$1"
    if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
        return 0
    fi

    python3 - "$config_path" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
try:
    data = json.loads(config_path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"❌ Failed to parse JSON config ({config_path}): {exc}", file=sys.stderr)
    raise SystemExit(1)

value = data.get("default_resources_url", "")
if not isinstance(value, str):
    print("❌ package.json field 'default_resources_url' must be a string.", file=sys.stderr)
    raise SystemExit(1)

print(value.strip())
PY
}


normalize_default_resources_url() {
    local candidate_url="$1"

    if [[ "$candidate_url" =~ ^https?://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$ ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        local ref="${BASH_REMATCH[3]}"
        local path="${BASH_REMATCH[4]}"
        printf 'https://raw.githubusercontent.com/%s/%s/%s/%s\n' "$owner" "$repo" "$ref" "$path"
        return 0
    fi

    printf '%s\n' "$candidate_url"
    return 0
}


resolve_default_resources_manifest() {
    local manifest_tmp_dir="$1"
    local fetched_manifest_path="$manifest_tmp_dir/default-resources-remote.json"
    local empty_manifest_path="$manifest_tmp_dir/default-resources-empty.json"
    local baked_manifest_path=""
    local config_path=""
    local default_resources_url=""

    if [ -n "${SCRIPT_DIR:-}" ]; then
        baked_manifest_path="$SCRIPT_DIR/default-resources.json"
    fi

    config_path="$(default_resources_config_path)"
    if ! default_resources_url="$(read_default_resources_url_from_config "$config_path")"; then
        echo "⚠️ Failed to read default_resources_url from package.json. Skipping defaults for this run." >&2
        default_resources_url=""
    fi
    default_resources_url="$(normalize_default_resources_url "$default_resources_url")"

    if [ -z "$default_resources_url" ]; then
        echo "⚠️ package.json default_resources_url is empty. Skipping defaults for this run." >&2
    elif curl_download_to_file "$default_resources_url" "$fetched_manifest_path"; then
        if [ -s "$fetched_manifest_path" ]; then
            echo "Loaded remote default resources manifest: $default_resources_url" >&2
            printf '%s\n' "$fetched_manifest_path"
            return 0
        fi
        echo "⚠️ Remote default resources manifest is empty. Skipping defaults for this run." >&2
    else
        echo "⚠️ Failed to download remote default resources manifest: $default_resources_url" >&2
        echo "⚠️ Continuing with project resources only (default resources skipped for this run)." >&2
    fi

    if [ -n "$baked_manifest_path" ] && [ -f "$baked_manifest_path" ]; then
        echo "ℹ️ Baked default resources manifest exists at: $baked_manifest_path (not used when remote defaults are unavailable)." >&2
    fi

    cat > "$empty_manifest_path" <<'EOF'
{
  "custom_nodes": [],
  "models": [],
  "files": []
}
EOF
    printf '%s\n' "$empty_manifest_path"
    return 0
}
