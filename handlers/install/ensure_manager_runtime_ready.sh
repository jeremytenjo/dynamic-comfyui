# shellcheck shell=bash

manager_runtime_pip_install() {
    local -a install_target_args=("$@")
    local -a pip_args=(install "${install_target_args[@]}")

    if [ -n "$NETWORK_VOLUME" ] && [ "$NETWORK_VOLUME" != "/" ] && [ -d "$NETWORK_VOLUME" ] && [ -w "$NETWORK_VOLUME" ]; then
        local pip_cache_dir="$NETWORK_VOLUME/.cache/pip"
        if mkdir -p "$pip_cache_dir"; then
            echo "Using persistent pip cache for manager requirements: $pip_cache_dir"
            pip_args=(install --cache-dir "$pip_cache_dir" "${install_target_args[@]}")
        else
            echo "⚠️ Could not create pip cache dir for manager requirements; using no cache."
            pip_args=(install --no-cache-dir "${install_target_args[@]}")
        fi
    else
        echo "Using no pip cache for manager requirements (no writable persistent network volume detected)."
        pip_args=(install --no-cache-dir "${install_target_args[@]}")
    fi

    python3 -m pip "${pip_args[@]}"
}


ensure_cm_cli_ready() {
    if command -v cm-cli > /dev/null 2>&1; then
        return 0
    fi

    echo "cm-cli not found; installing comfyui-manager package..."
    if ! manager_runtime_pip_install comfyui-manager; then
        echo "⚠️ Failed to install comfyui-manager package for cm-cli."
        return 0
    fi

    if ! command -v cm-cli > /dev/null 2>&1; then
        echo "⚠️ cm-cli is still unavailable after install. ComfyUI may warn about manager flag injection."
        return 0
    fi

    return 0
}


ensure_manager_runtime_ready() {
    local manager_reqs="$COMFYUI_DIR/manager_requirements.txt"

    if [ ! -f "$manager_reqs" ]; then
        echo "❌ Missing manager requirements file: $manager_reqs"
        return 1
    fi

    echo "Installing ComfyUI manager runtime requirements..."
    manager_runtime_pip_install -r "$manager_reqs"
    ensure_cm_cli_ready
}
