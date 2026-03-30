# shellcheck shell=bash


install_sentinel_path() {
    echo "$NETWORK_VOLUME/.avatary_install_complete"
}


clear_install_sentinel() {
    local sentinel
    sentinel="$(install_sentinel_path)"
    rm -f "$sentinel"
}


write_install_sentinel() {
    local sentinel
    sentinel="$(install_sentinel_path)"
    cat > "$sentinel" <<EOF
installed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
comfyui_dir=$COMFYUI_DIR
EOF
    echo "✅ Wrote install sentinel: $sentinel"
}


verify_install_sentinel() {
    local sentinel
    sentinel="$(install_sentinel_path)"
    [ -f "$sentinel" ]
}


verify_key_installed_assets() {
    local -a required_paths=(
        "$COMFYUI_DIR/models/vae/ae.safetensors"
        "$COMFYUI_DIR/models/text_encoders/qwen_3_4b.safetensors"
        "$COMFYUI_DIR/models/diffusion_models/z_image_bf16.safetensors"
        "$COMFYUI_DIR/custom_nodes/comfyui-manager/cm-cli.py"
    )
    local path
    for path in "${required_paths[@]}"; do
        if [ ! -f "$path" ]; then
            echo "❌ Missing required installed asset: $path"
            return 1
        fi
    done
    return 0
}


assert_install_complete_for_startup() {
    if ! verify_install_sentinel; then
        echo "❌ Installation has not been completed."
        echo "Run 'bash /install.sh' from the Jupyter terminal, then restart the pod."
        return 1
    fi

    if ! verify_key_installed_assets; then
        echo "❌ Installation marker exists, but required assets are missing."
        echo "Run 'bash /install.sh' again from the Jupyter terminal."
        return 1
    fi

    return 0
}
