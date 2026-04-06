# shellcheck shell=bash


stop_existing_comfyui_service() {
    local workspace_dir="$1"
    comfy --workspace="$workspace_dir" stop >/dev/null 2>&1 || true
    sleep 1
}


start_comfyui_service() {
    local now_ts
    local metric_start_ts
    now_ts=$(date +%s)
    metric_start_ts="$now_ts"

    # When running full install flow, include install/download time in startup metric.
    if [ -n "${INSTALL_START_TS:-}" ] && [[ "${INSTALL_START_TS:-}" =~ ^[0-9]+$ ]] && [ "$INSTALL_START_TS" -le "$now_ts" ]; then
        metric_start_ts="$INSTALL_START_TS"
    fi

    local url="http://127.0.0.1:8188"
    local comfy_health_url="$url/system_stats"
    local -a comfy_args=(--listen --enable-manager --disable-cuda-malloc)

    if ! ensure_comfy_cli_ready; then
        echo "comfy-cli is not ready; refusing to start ComfyUI."
        return 1
    fi

    if is_http_reachable "$comfy_health_url" 2 5; then
        echo "ComfyUI is already running; restarting to load newly installed files and custom nodes."
    else
        echo "Ensuring no stale ComfyUI background service is running before launch."
    fi

    stop_existing_comfyui_service "$COMFYUI_DIR"

    stop_setup_instructions_page

    apply_flash_attn_runtime_hotfix
    configure_torch_cuda_allocator

    if ! ensure_manager_runtime_ready; then
        echo "ComfyUI manager runtime setup failed; refusing to start ComfyUI with --enable-manager."
        return 1
    fi

    echo "Starting ComfyUI via comfy-cli"
    if ! cd "$COMFYUI_DIR"; then
        echo "Failed to cd into ComfyUI workspace: $COMFYUI_DIR"
        return 1
    fi
    if ! comfy --workspace="$COMFYUI_DIR" launch --background -- "${comfy_args[@]}"; then
        echo "Failed to start ComfyUI via comfy-cli."
        return 1
    fi

    local counter=0
    local max_wait=90

    until is_http_reachable "$comfy_health_url" 2 5; do
        if [ $counter -ge $max_wait ]; then
            echo "ComfyUI failed to become ready within ${max_wait}s."
            stop_existing_comfyui_service "$COMFYUI_DIR"
            return 1
        fi

        echo "🔄  ComfyUI starting..."
        sleep 2
        counter=$((counter + 2))
    done

    local end_ts
    local elapsed_seconds
    local elapsed_minutes
    local elapsed_remaining_seconds
    end_ts=$(date +%s)
    elapsed_seconds=$((end_ts - metric_start_ts))
    elapsed_minutes=$((elapsed_seconds / 60))
    elapsed_remaining_seconds=$((elapsed_seconds % 60))

    if [ "$elapsed_minutes" -gt 0 ]; then
        echo "🚀 ComfyUI is UP (${elapsed_minutes}m ${elapsed_remaining_seconds}s)"
    else
        echo "🚀 ComfyUI is UP (${elapsed_seconds}s)"
    fi
    return 0
}
