# shellcheck shell=bash

projects_settings_path() {
    echo "/workspace/settings.yaml"
}


derive_projects_repo_api_url() {
    local settings_path
    settings_path="$(projects_settings_path)"

    if [ ! -f "$settings_path" ]; then
        echo "❌ Missing required settings file: $settings_path"
        echo "❌ Required key: github.owner_url"
        return 1
    fi

    if [ ! -r "$settings_path" ]; then
        echo "❌ Cannot read required settings file: $settings_path"
        echo "❌ Required key: github.owner_url"
        return 1
    fi

    local derived_api_url
    if ! derived_api_url="$(
        python3 - "$settings_path" <<'PY'
import re
import sys
from pathlib import Path

import yaml

settings_path = Path(sys.argv[1])
required_key = "github.owner_url"

try:
    raw = settings_path.read_text(encoding="utf-8")
except Exception as exc:
    print(f"❌ Failed to read required settings file {settings_path}: {exc}", file=sys.stderr)
    print(f"❌ Required key: {required_key}", file=sys.stderr)
    raise SystemExit(1)

try:
    data = yaml.safe_load(raw)
except Exception as exc:
    print(f"❌ Invalid YAML in required settings file {settings_path}: {exc}", file=sys.stderr)
    print(f"❌ Required key: {required_key}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(data, dict):
    print(f"❌ Invalid settings format in {settings_path}: expected a mapping at root.", file=sys.stderr)
    print(f"❌ Required key: {required_key}", file=sys.stderr)
    raise SystemExit(1)

github_config = data.get("github")
if not isinstance(github_config, dict):
    print(f"❌ Missing required key in {settings_path}: {required_key}", file=sys.stderr)
    raise SystemExit(1)

owner_url = github_config.get("owner_url")
if not isinstance(owner_url, str) or not owner_url.strip():
    print(f"❌ Missing required key in {settings_path}: {required_key}", file=sys.stderr)
    raise SystemExit(1)

candidate = owner_url.strip()
match = re.match(r"^https?://github\.com/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", candidate)
if not match:
    print(
        f"❌ Invalid github.owner_url in {settings_path}: {candidate}. "
        "Expected format: https://github.com/<owner>/<repo>",
        file=sys.stderr,
    )
    print(f"❌ Required key: {required_key}", file=sys.stderr)
    raise SystemExit(1)

owner = match.group(1)
repo = match.group(2)
print(f"https://api.github.com/repos/{owner}/{repo}/contents/projects?ref=main")
PY
    )"; then
        return 1
    fi

    printf '%s\n' "$derived_api_url"
    return 0
}


refresh_project_manifests() {
    local repo_api_url=""
    if ! repo_api_url="$(derive_projects_repo_api_url)"; then
        return 1
    fi
    local target_dir="$NETWORK_VOLUME/projects"

    mkdir -p "$target_dir"

    local sync_tmp_dir
    sync_tmp_dir="$(mktemp -d /tmp/dynamic-comfyui-project-sync.XXXXXX)"

    local listing_json
    if ! listing_json="$(curl --silent --show-error --fail "$repo_api_url")"; then
        echo "⚠️ Failed to fetch project manifest list from GitHub."
        rm -rf "$sync_tmp_dir"
        return 1
    fi

    local listing_file="$sync_tmp_dir/listing.json"
    printf '%s' "$listing_json" > "$listing_file"

    local downloads_file="$sync_tmp_dir/downloads.tsv"
    if ! python3 - "$downloads_file" "$listing_file" <<'PY'; then
import json
import sys
from pathlib import Path

out_path = Path(sys.argv[1])
listing_path = Path(sys.argv[2])

try:
    payload = json.loads(listing_path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"Failed to parse GitHub response: {exc}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(payload, list):
    print("Unexpected GitHub response type.", file=sys.stderr)
    raise SystemExit(1)

rows = []
for item in payload:
    if not isinstance(item, dict):
        continue
    name = item.get("name")
    download_url = item.get("download_url")
    item_type = item.get("type")
    if item_type != "file":
        continue
    if not isinstance(name, str) or not isinstance(download_url, str):
        continue
    if not (name.endswith(".yaml") or name.endswith(".yml")):
        continue
    rows.append((name, download_url))

if not rows:
    print("No project manifests found in GitHub projects directory.", file=sys.stderr)
    raise SystemExit(1)

rows.sort(key=lambda row: row[0])
out_path.write_text("".join(f"{name}\t{url}\n" for name, url in rows), encoding="utf-8")
PY
        echo "⚠️ Failed to parse project manifest list from GitHub."
        rm -rf "$sync_tmp_dir"
        return 1
    fi

    local filename
    local download_url
    local synced_count=0
    while IFS=$'\t' read -r filename download_url; do
        [ -n "$filename" ] || continue
        if ! curl --silent --show-error --fail --location "$download_url" --output "$sync_tmp_dir/$filename"; then
            echo "⚠️ Failed to download project manifest: $filename"
            rm -rf "$sync_tmp_dir"
            return 1
        fi
        synced_count=$((synced_count + 1))
    done < "$downloads_file"

    if [ "$synced_count" -eq 0 ]; then
        echo "⚠️ No project manifests downloaded from GitHub."
        rm -rf "$sync_tmp_dir"
        return 1
    fi

    find "$target_dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -delete
    while IFS=$'\t' read -r filename download_url; do
        [ -n "$filename" ] || continue
        cp -f "$sync_tmp_dir/$filename" "$target_dir/$filename"
    done < "$downloads_file"

    rm -rf "$sync_tmp_dir"
    echo "Synced $synced_count project manifest(s) from GitHub."
    return 0
}
