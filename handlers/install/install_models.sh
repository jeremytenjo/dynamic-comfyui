# shellcheck shell=bash


download_model_with_comfy_cli() {
    local url="$1"
    local full_path="$2"
    local relative_path="${full_path#"$COMFYUI_DIR"/}"
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

    comfy --workspace="$COMFYUI_DIR" model download --url "$url" --relative-path "$relative_path" || rc=$?

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
    local -a model_specs=(
        "https://huggingface.co/avatary-ai/files/resolve/main/ae.safetensors|$VAE_DIR/ae.safetensors"
        "https://huggingface.co/avatary-ai/files/resolve/main/qwen_3_4b.safetensors|$TEXT_ENCODERS_DIR/qwen_3_4b.safetensors"
        "https://huggingface.co/avatary-ai/files/resolve/main/Qwen3-4b-Z-Image-Engineer-V4-F16.gguf|$TEXT_ENCODERS_DIR/Qwen3-4b-Z-Image-Engineer-V4-F16.gguf"
        "https://huggingface.co/avatary-ai/files/resolve/main/z_image_bf16.safetensors|$DIFFUSION_MODELS_DIR/z_image_bf16.safetensors"
        "https://huggingface.co/avatary-ai/files/resolve/main/z_image_turbo_bf16.safetensors|$DIFFUSION_MODELS_DIR/z_image_turbo.safetensors"
        "https://huggingface.co/avatary-ai/files/resolve/main/z_image_turbo.safetensors|$DIFFUSION_MODELS_DIR/z-image-turbo-nsfw.safetensors"
        "https://huggingface.co/avatary-ai/files/resolve/main/z_image_vae.safetensors|$VAE_DIR/z_image_vae.safetensors"
        "https://huggingface.co/avatary-ai/files/resolve/main/Z-Image-AbliteratedV1.f16.gguf|$TEXT_ENCODERS_DIR/Z-Image-AbliteratedV1.f16.gguf"
        "https://huggingface.co/avatary-ai/files/resolve/main/Z-Image-AbliteratedV1.f16.safetensors|$TEXT_ENCODERS_DIR/Z-Image-AbliteratedV1.f16.safetensors"
        "https://huggingface.co/avatary-ai/files/resolve/main/seedvr2_ema_7b_fp16.safetensors|$SEEDVR2_DIR/seedvr2_ema_7b_fp16.safetensors"
        "https://huggingface.co/avatary-ai/files/resolve/main/ema_vae_fp16.safetensors|$SEEDVR2_DIR/ema_vae_fp16.safetensors"
        "https://huggingface.co/avatary-ai/files/resolve/main/sam3.pt|$SAM3_DIR/sam3.pt"
    )

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
        local model_path
        IFS='|' read -r model_url model_path <<< "$model_spec"
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
