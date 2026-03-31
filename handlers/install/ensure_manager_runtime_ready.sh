# shellcheck shell=bash

manager_runtime_pip_install() {
    local requirements_file="$1"
    local -a pip_args=(install -r "$requirements_file")

    if [ -n "$NETWORK_VOLUME" ] && [ "$NETWORK_VOLUME" != "/" ] && [ -d "$NETWORK_VOLUME" ] && [ -w "$NETWORK_VOLUME" ]; then
        local pip_cache_dir="$NETWORK_VOLUME/.cache/pip"
        if mkdir -p "$pip_cache_dir"; then
            echo "Using persistent pip cache for manager requirements: $pip_cache_dir"
            pip_args=(install --cache-dir "$pip_cache_dir" -r "$requirements_file")
        else
            echo "⚠️ Could not create pip cache dir for manager requirements; using no cache."
            pip_args=(install --no-cache-dir -r "$requirements_file")
        fi
    else
        echo "Using no pip cache for manager requirements (no writable persistent network volume detected)."
        pip_args=(install --no-cache-dir -r "$requirements_file")
    fi

    python3 -m pip "${pip_args[@]}"
}


ensure_manager_runtime_ready() {
    local manager_reqs="$COMFYUI_DIR/manager_requirements.txt"

    if [ ! -f "$manager_reqs" ]; then
        echo "❌ Missing manager requirements file: $manager_reqs"
        return 1
    fi

    echo "Installing ComfyUI manager runtime requirements..."
    manager_runtime_pip_install "$manager_reqs"
}
