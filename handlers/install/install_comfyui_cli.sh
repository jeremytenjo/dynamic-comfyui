# shellcheck shell=bash


install_comfy_cli_package() {
    local -a pip_args=(install comfy-cli)
    local pip_cache_dir=""

    if [ -n "$NETWORK_VOLUME" ] && [ "$NETWORK_VOLUME" != "/" ] && [ -d "$NETWORK_VOLUME" ] && [ -w "$NETWORK_VOLUME" ]; then
        pip_cache_dir="$NETWORK_VOLUME/.cache/pip"
        if mkdir -p "$pip_cache_dir"; then
            echo "Using persistent pip cache: $pip_cache_dir"
            pip_args=(install --cache-dir "$pip_cache_dir" comfy-cli)
        else
            echo "⚠️ Could not create persistent pip cache dir, falling back to no cache."
            pip_args=(install --no-cache-dir comfy-cli)
        fi
    else
        echo "Using no pip cache (no writable persistent network volume detected)."
        pip_args=(install --no-cache-dir comfy-cli)
    fi

    python3 -m pip "${pip_args[@]}"
}


ensure_comfy_cli_ready() {
    if command -v comfy > /dev/null 2>&1; then
        return 0
    fi

    echo "Installing comfy-cli..."
    if ! install_comfy_cli_package; then
        echo "❌ Failed to install comfy-cli."
        return 1
    fi

    if ! command -v comfy > /dev/null 2>&1; then
        echo "❌ comfy-cli installation completed but 'comfy' command is not available."
        return 1
    fi

    return 0
}


install_comfyui_with_comfy_cli() {
    if ! ensure_comfy_cli_ready; then
        return 1
    fi

    echo "Installing/updating ComfyUI workspace via comfy-cli..."
    if ! comfy --workspace="$COMFYUI_DIR" install; then
        echo "❌ comfy-cli failed to install/update ComfyUI at $COMFYUI_DIR"
        return 1
    fi

    return 0
}
