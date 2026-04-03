# shellcheck shell=bash


prepare_network_volume_and_start_jupyter() {
    local notebook_dir="/workspace"
    local jupyter_log="/tmp/dynamic-comfyui-jupyter.log"
    local -a jupyter_cmd=()

    # Check if NETWORK_VOLUME exists; if not, use root directory instead.
    if [ ! -d "$NETWORK_VOLUME" ]; then
        echo "NETWORK_VOLUME directory '$NETWORK_VOLUME' does not exist. You are NOT using a network volume. Setting NETWORK_VOLUME to '/' (root directory)."
        NETWORK_VOLUME="/"
        notebook_dir="/"
    fi

    if command -v jupyter-lab >/dev/null 2>&1; then
        jupyter_cmd=(jupyter-lab)
    elif command -v jupyter >/dev/null 2>&1; then
        jupyter_cmd=(jupyter lab)
    else
        echo "❌ JupyterLab is not installed in this image."
        return 1
    fi

    rm -f "$jupyter_log"
    echo "Starting JupyterLab on 0.0.0.0:8888 (root: $notebook_dir)"
    # Use explicit ServerApp options so proxy target is deterministic on RunPod.
    nohup "${jupyter_cmd[@]}" \
        --ip=0.0.0.0 \
        --port=8888 \
        --ServerApp.port=8888 \
        --ServerApp.port_retries=0 \
        --allow-root \
        --no-browser \
        --ServerApp.allow_origin='*' \
        --ServerApp.allow_credentials=True \
        --ServerApp.root_dir="$notebook_dir" \
        --notebook-dir="$notebook_dir" >"$jupyter_log" 2>&1 &

    local jupyter_pid=$!
    local waited=0
    local max_wait=25

    while [ "$waited" -lt "$max_wait" ]; do
        if ! kill -0 "$jupyter_pid" 2>/dev/null; then
            echo "❌ JupyterLab process exited during startup."
            echo "Last Jupyter logs:"
            tail -n 60 "$jupyter_log" || true
            return 1
        fi

        if is_http_reachable "http://127.0.0.1:8888/lab" 2 5; then
            echo "JupyterLab is ready on port 8888."
            return 0
        fi

        sleep 1
        waited=$((waited + 1))
    done

    echo "❌ JupyterLab did not become reachable on port 8888 within ${max_wait}s."
    echo "Last Jupyter logs:"
    tail -n 60 "$jupyter_log" || true
    return 1
}
