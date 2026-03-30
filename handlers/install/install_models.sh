# shellcheck shell=bash


download_model_with_wget() {
    local url="$1"
    local full_path="$2"
    local hf_token="${HUGGINGFACE_TOKEN:-}"
    local start_ts
    local rc=0
    start_ts=$(date +%s)

    local destination_dir
    local destination_file
    destination_dir=$(dirname "$full_path")
    destination_file=$(basename "$full_path")

    mkdir -p "$destination_dir"

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

    local -a wget_args=(
        --continue
        --tries=5
        --waitretry=2
        --timeout=30
        --read-timeout=30
        --output-document="$full_path"
    )
    if [ -n "$hf_token" ]; then
        wget_args+=(--header="Authorization: Bearer $hf_token")
    else
        echo "⚠️  HUGGINGFACE_TOKEN not set; downloading without Authorization header."
    fi

    wget "${wget_args[@]}" "$url" || rc=$?

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


install_models_with_wget() {
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

    local total_models=${#model_specs[@]}
    local model_idx=0
    local model_spec
    for model_spec in "${model_specs[@]}"; do
        local model_url
        local model_path
        IFS='|' read -r model_url model_path <<< "$model_spec"
        model_idx=$((model_idx + 1))
        echo "⬇️ [$model_idx/$total_models] Downloading $(basename "$model_path")"
        if ! download_model_with_wget "$model_url" "$model_path"; then
            return 1
        fi
    done

    if [ -d "$LORAS_DIR" ]; then
        local file
        for file in "$LORAS_DIR"/*.zip; do
            [ -f "$file" ] || continue
            mv "$file" "${file%.zip}.safetensors"
        done
    fi

    return 0
}
