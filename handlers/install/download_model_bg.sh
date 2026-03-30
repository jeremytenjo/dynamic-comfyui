# shellcheck shell=bash


download_model_bg() {
    local url="$1"
    local full_path="$2"
    download_model "$url" "$full_path" &
    PRIMARY_MODEL_DOWNLOAD_PIDS+=($!)
    PRIMARY_MODEL_DOWNLOAD_LABELS+=("$full_path")
}
