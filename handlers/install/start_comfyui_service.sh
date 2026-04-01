# shellcheck shell=bash


start_comfyui_service() {
    local start_ts
    start_ts=$(date +%s)
    local url="http://127.0.0.1:8188"
    local comfy_health_url="$url/system_stats"
    local -a comfy_args=(--listen --enable-manager --disable-cuda-malloc)

    if ! ensure_comfy_cli_ready; then
        echo "comfy-cli is not ready; refusing to start ComfyUI."
        return 1
    fi

    if curl --silent --fail "$comfy_health_url" --output /dev/null; then
        echo "ComfyUI is already running; restarting to load newly installed models and custom nodes."
        comfy --workspace="$COMFYUI_DIR" stop >/dev/null 2>&1 || true
        local -a existing_pids=()
        while IFS= read -r pid; do
            [ -n "$pid" ] && existing_pids+=("$pid")
        done < <(ps -eo pid=,args= | awk '/[p]ython3 .*main\.py|[c]omfy .* launch/ {print $1}')

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

    until curl --silent --fail "$comfy_health_url" --output /dev/null; do
        if [ $counter -ge $max_wait ]; then
            echo "ComfyUI failed to become ready within ${max_wait}s."
            comfy --workspace="$COMFYUI_DIR" stop >/dev/null 2>&1 || true
            return 1
        fi

        echo "🔄  ComfyUI starting..."
        sleep 2
        counter=$((counter + 2))
    done

    local end_ts
    local elapsed_seconds
    local elapsed_minutes
    end_ts=$(date +%s)
    elapsed_seconds=$((end_ts - start_ts))
    elapsed_minutes=$(( (elapsed_seconds + 59) / 60 ))

    echo "🚀 ComfyUI is UP (${elapsed_minutes} minute(s))"
    return 0
}
