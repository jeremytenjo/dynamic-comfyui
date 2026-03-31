# shellcheck shell=bash


download_model_with_comfy_cli() {
    local url="$1"
    local full_path="$2"
    local relative_path="${full_path#"$COMFYUI_DIR"/}"
    local relative_dir
    relative_dir=$(dirname "$relative_path")
    local start_ts
    local rc=0
    start_ts=$(date +%s)

    local destination_file
    destination_file=$(basename "$full_path")

    if [ -f "$full_path" ]; then
        local size_bytes
        size_bytes=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo 0)
        if [ "$size_bytes" -lt 10485760 ]; then
            echo "🗑️  Deleting corrupted file: $full_path"
            rm -f "$full_path"
        else
            echo "✅ $destination_file already exists, skipping."
            log_timing "direct_download" "$destination_file" "skipped_existing" "$start_ts" "$(date +%s)" "$size_bytes" "$url"
            return 0
        fi
    fi

    local model_help
    model_help="$(comfy model download --help 2>/dev/null || true)"
    local -a comfy_model_download_cmd=(comfy)
    while IFS= read -r arg; do
        [ -n "$arg" ] && comfy_model_download_cmd+=("$arg")
    done < <(comfy_global_noninteractive_args)
    comfy_model_download_cmd+=(--workspace="$COMFYUI_DIR" model download --url "$url")

    if printf '%s' "$model_help" | grep -q -- '--filename'; then
        if printf '%s' "$model_help" | grep -q -- '--relative-path'; then
            comfy_model_download_cmd+=(--relative-path "$relative_dir")
        fi
        comfy_model_download_cmd+=(--filename "$destination_file")
    elif printf '%s' "$model_help" | grep -q -- '--relative-path'; then
        comfy_model_download_cmd+=(--relative-path "$relative_path")
    fi

    "${comfy_model_download_cmd[@]}" || rc=$?

    local size_bytes
    local end_ts
    size_bytes=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo 0)
    end_ts=$(date +%s)
    if [ $rc -eq 0 ]; then
        log_timing "direct_download" "$destination_file" "success" "$start_ts" "$end_ts" "$size_bytes" "$url"
        echo "✅ Downloaded: $destination_file"
    else
        log_timing "direct_download" "$destination_file" "failed" "$start_ts" "$end_ts" "$size_bytes" "$url"
        echo "❌ Failed to download: $destination_file"
    fi

    return $rc
}


install_models_with_comfy_cli() {
    if [ -z "${INSTALL_MANIFEST_MODELS_FILE:-}" ] || [ ! -f "$INSTALL_MANIFEST_MODELS_FILE" ]; then
        echo "❌ Manifest model data is missing. Ensure load_install_manifest ran successfully."
        return 1
    fi

    local -a model_specs=()
    local model_line
    while IFS= read -r model_line; do
        [ -n "$model_line" ] || continue
        model_specs+=("$model_line")
    done < "$INSTALL_MANIFEST_MODELS_FILE"

    if [ "${#model_specs[@]}" -eq 0 ]; then
        echo "No models defined in install manifest; skipping model installation."
        return 0
    fi

    if ! ensure_comfy_cli_ready; then
        echo "❌ comfy-cli is not available."
        return 1
    fi

    # comfy-cli uses HF_API_TOKEN for Hugging Face auth; map legacy env var once.
    if [ -n "${HUGGINGFACE_TOKEN:-}" ] && [ -z "${HF_API_TOKEN:-}" ]; then
        export HF_API_TOKEN="$HUGGINGFACE_TOKEN"
    fi
    if [ -z "${HF_API_TOKEN:-}" ]; then
        echo "⚠️  HF_API_TOKEN not set; downloading without HF auth token."
    fi

    local total_models=${#model_specs[@]}
    local model_idx=0
    local -a model_download_pids=()
    local -a model_download_labels=()
    local model_spec
    for model_spec in "${model_specs[@]}"; do
        local model_url
        local model_target
        local model_path
        IFS=$'\t' read -r model_url model_target <<< "$model_spec"
        model_path="$COMFYUI_DIR/$model_target"
        mkdir -p "$(dirname "$model_path")"
        model_idx=$((model_idx + 1))
        echo "⬇️ [$model_idx/$total_models] Queueing $(basename "$model_path")"
        download_model_with_comfy_cli "$model_url" "$model_path" &
        model_download_pids+=($!)
        model_download_labels+=("$model_path")
    done

    local failed_downloads=0
    local i
    for i in "${!model_download_pids[@]}"; do
        local pid="${model_download_pids[$i]}"
        local label="${model_download_labels[$i]}"
        if ! wait "$pid"; then
            failed_downloads=$((failed_downloads + 1))
            echo "❌ Model download failed: $label"
        fi
    done

    if [ "$failed_downloads" -gt 0 ]; then
        echo "❌ $failed_downloads model download task(s) failed."
        return 1
    fi

    if [ -d "$LORAS_DIR" ]; then
        local file
        for file in "$LORAS_DIR"/*.zip; do
            [ -f "$file" ] || continue
            mv "$file" "${file%.zip}.safetensors"
        done
    fi

    return 0
}
