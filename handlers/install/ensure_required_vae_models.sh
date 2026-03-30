# shellcheck shell=bash


ensure_required_vae_models() {
    local missing=0
    local vae_path=""
    local -a required_vae_models=(
        "$VAE_DIR/ae.safetensors"
        "$VAE_DIR/z_image_vae.safetensors"
    )

    for vae_path in "${required_vae_models[@]}"; do
        if [ ! -f "$vae_path" ]; then
            echo "❌ Missing VAE model: $vae_path"
            missing=$((missing + 1))
            continue
        fi

        local size_bytes
        size_bytes=$(stat -f%z "$vae_path" 2>/dev/null || stat -c%s "$vae_path" 2>/dev/null || echo 0)
        if [ "$size_bytes" -lt 10485760 ]; then
            echo "❌ VAE model appears incomplete (<10MB): $vae_path"
            missing=$((missing + 1))
        fi
    done

    if [ "$missing" -gt 0 ]; then
        log_timing "preflight" "vae_models" "failed_missing_or_incomplete" "$INSTALL_START_TS" "$(date +%s)" "0" "$VAE_DIR"
        return 1
    fi

    log_timing "preflight" "vae_models" "success" "$INSTALL_START_TS" "$(date +%s)" "0" "$VAE_DIR"
    return 0
}
