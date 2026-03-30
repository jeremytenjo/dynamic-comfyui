# shellcheck shell=bash


ensure_manager_runtime_ready() {
    local manager_reqs="$NETWORK_VOLUME/ComfyUI/manager_requirements.txt"

    if [ ! -f "$manager_reqs" ]; then
        echo "❌ Missing manager requirements file: $manager_reqs"
        return 1
    fi

    echo "Installing ComfyUI manager runtime requirements..."
    python3 -m pip install --no-cache-dir -r "$manager_reqs"
}
