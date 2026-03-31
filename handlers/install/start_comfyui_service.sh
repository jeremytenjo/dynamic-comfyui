# shellcheck shell=bash


start_comfyui_service() {
    local url="http://127.0.0.1:8188"
    local comfy_health_url="$url/system_stats"
    local comfy_log_path="$NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID:-pod}_nohup.log"
    local -a comfy_args=(--listen --enable-manager --disable-cuda-malloc)

    if curl --silent --fail "$comfy_health_url" --output /dev/null; then
        echo "ComfyUI is already running; restarting to load newly installed models and custom nodes."
        local -a existing_pids=()
        while IFS= read -r pid; do
            [ -n "$pid" ] && existing_pids+=("$pid")
        done < <(ps -eo pid=,args= | awk '/[p]ython3 .*main\.py/ {print $1}')

        if [ "${#existing_pids[@]}" -gt 0 ]; then
            kill "${existing_pids[@]}" 2>/dev/null || true
            sleep 3
            local pid
            for pid in "${existing_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    kill -9 "$pid" 2>/dev/null || true
                fi
            done
        fi
    fi

    stop_setup_instructions_page

    apply_flash_attn_runtime_hotfix
    configure_torch_cuda_allocator

    if ! ensure_manager_runtime_ready; then
        echo "ComfyUI manager runtime setup failed; refusing to start ComfyUI with --enable-manager."
        return 1
    fi

    echo "Starting ComfyUI"
    if ! cd "$COMFYUI_DIR"; then
        echo "Failed to cd into ComfyUI workspace: $COMFYUI_DIR"
        return 1
    fi
    nohup python3 main.py "${comfy_args[@]}" > "$comfy_log_path" 2>&1 &
    local comfy_pid=$!

    local counter=0
    local max_wait=90

    until curl --silent --fail "$comfy_health_url" --output /dev/null; do
        if [ $counter -ge $max_wait ]; then
            echo "ComfyUI failed to become ready within ${max_wait}s. Check logs at $comfy_log_path"
            if kill -0 "$comfy_pid" 2>/dev/null; then
                kill "$comfy_pid" 2>/dev/null || true
            fi
            return 1
        fi

        echo "🔄  ComfyUI starting... startup logs: $comfy_log_path"
        sleep 2
        counter=$((counter + 2))
    done

    echo "🚀 ComfyUI is UP"
    return 0
}
