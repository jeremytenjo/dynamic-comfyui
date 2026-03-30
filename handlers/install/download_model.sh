# shellcheck shell=bash

download_model() {
    local url="$1"
    local full_path="$2"
    local hf_token="${HUGGINGFACE_TOKEN:-}"
    local start_ts=$(date +%s)

    local destination_dir=$(dirname "$full_path")
    local destination_file=$(basename "$full_path")

    mkdir -p "$destination_dir"

    # Corruption check
    if [ -f "$full_path" ]; then
        local size_bytes=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo 0)
        if [ "$size_bytes" -lt 10485760 ]; then
            echo "🗑️  Deleting corrupted file: $full_path"
            rm -f "$full_path"
        else
            echo "✅ $destination_file already exists, skipping."
            log_timing "direct_download" "$destination_file" "skipped_existing" "$start_ts" "$(date +%s)" "$size_bytes" "$url"
            return 0
        fi
    fi

    local -a curl_args=(
        --silent
        --show-error
        --fail
        --location
        --output "$full_path"
    )
    if [ -n "$hf_token" ]; then
        curl_args+=(--header "Authorization: Bearer $hf_token")
    else
        echo "⚠️  HUGGINGFACE_TOKEN not set; downloading without Authorization header."
    fi
    curl "${curl_args[@]}" "$url"
    local rc=$?
    local size_bytes=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo 0)
    local end_ts=$(date +%s)
    if [ $rc -eq 0 ]; then
        log_timing "direct_download" "$destination_file" "success" "$start_ts" "$end_ts" "$size_bytes" "$url"
    else
        log_timing "direct_download" "$destination_file" "failed" "$start_ts" "$end_ts" "$size_bytes" "$url"
    fi

    echo "⬇️ Downloading in background: $destination_file"
    return $rc
}
