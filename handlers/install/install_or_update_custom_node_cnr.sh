# shellcheck shell=bash


install_or_update_custom_node_cnr() {
    local cnr_id="$1"
    local repo_dir="$2"
    local cnr_version="$3"
    local node_path="$CUSTOM_NODES_DIR/$repo_dir"
    local start_ts
    local end_ts
    local rc=0
    local archive_name=""
    local archive_path=""
    local metadata_json=""
    local download_url=""
    local resolved_version=""
    start_ts=$(date +%s)

    metadata_json="$(curl --silent --show-error -fL "https://api.comfy.org/nodes/${cnr_id}/install?version=${cnr_version}")" || rc=$?
    if [ $rc -ne 0 ]; then
        end_ts=$(date +%s)
        log_timing "custom_node_install" "$repo_dir" "install_failed" "$start_ts" "$end_ts" "0" "cnr:${cnr_id}@${cnr_version}"
        return $rc
    fi

    download_url="$(printf '%s' "$metadata_json" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("downloadUrl") or "").strip())')"
    resolved_version="$(printf '%s' "$metadata_json" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("version") or "").strip())')"
    if [ -z "$download_url" ] || [ -z "$resolved_version" ]; then
        end_ts=$(date +%s)
        log_timing "custom_node_install" "$repo_dir" "install_failed_invalid_metadata" "$start_ts" "$end_ts" "0" "cnr:${cnr_id}@${cnr_version}"
        return 1
    fi

    if [ -f "$node_path/.cnr-version" ] && [ -d "$node_path" ]; then
        local installed_version
        installed_version="$(cat "$node_path/.cnr-version" 2>/dev/null || true)"
        if [ "$installed_version" = "$resolved_version" ]; then
            end_ts=$(date +%s)
            log_timing "custom_node_install" "$repo_dir" "skipped_existing_version" "$start_ts" "$end_ts" "0" "cnr:${cnr_id}@${resolved_version}"
            return 0
        fi
    fi

    archive_name="CNR_${repo_dir}_$(date +%s).zip"
    archive_path="/tmp/${archive_name}"
    rm -f "$archive_path"
    curl --silent --show-error --fail --location --retry 5 --retry-delay 2 --continue-at - --output "$archive_path" "$download_url" || rc=$?
    if [ $rc -ne 0 ]; then
        end_ts=$(date +%s)
        log_timing "custom_node_install" "$repo_dir" "install_failed_download" "$start_ts" "$end_ts" "0" "$download_url"
        return $rc
    fi

    rm -rf "$node_path"
    mkdir -p "$node_path"
    python3 - "$archive_path" "$node_path" <<'PY'
import sys
import zipfile

archive_path = sys.argv[1]
target_dir = sys.argv[2]
with zipfile.ZipFile(archive_path, "r") as zf:
    zf.extractall(target_dir)
PY
    rc=$?
    rm -f "$archive_path"
    if [ $rc -ne 0 ]; then
        end_ts=$(date +%s)
        log_timing "custom_node_install" "$repo_dir" "install_failed_extract" "$start_ts" "$end_ts" "0" "cnr:${cnr_id}@${resolved_version}"
        return $rc
    fi

    echo "$resolved_version" > "$node_path/.cnr-version"
    end_ts=$(date +%s)
    log_timing "custom_node_install" "$repo_dir" "installed" "$start_ts" "$end_ts" "0" "cnr:${cnr_id}@${resolved_version}"

    # Install custom node dependencies when provided by the node pack.
    if [ -f "$node_path/requirements.txt" ]; then
        local dep_start_ts
        local dep_end_ts
        dep_start_ts=$(date +%s)
        pip install -r "$node_path/requirements.txt"
        rc=$?
        dep_end_ts=$(date +%s)
        if [ $rc -eq 0 ]; then
            log_timing "custom_node_deps" "$repo_dir" "success" "$dep_start_ts" "$dep_end_ts" "0" "$node_path/requirements.txt"
        else
            log_timing "custom_node_deps" "$repo_dir" "failed" "$dep_start_ts" "$dep_end_ts" "0" "$node_path/requirements.txt"
            return $rc
        fi
    else
        local dep_now_ts
        dep_now_ts=$(date +%s)
        log_timing "custom_node_deps" "$repo_dir" "skipped_no_requirements" "$dep_now_ts" "$dep_now_ts" "0" "$node_path"
    fi

    return 0
}
