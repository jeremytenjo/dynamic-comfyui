# shellcheck shell=bash


configure_torch_cuda_allocator() {
    # Stabilize allocator backend across process startup. ComfyUI can append
    # backend:cudaMallocAsync, which may conflict with inherited backend config.
    # Force expandable segments to reduce allocator fragmentation under heavy
    # VAE/video workloads.
    local raw_conf="${PYTORCH_CUDA_ALLOC_CONF:-}"
    local sanitized_conf=""
    local token=""

    if [ -n "$raw_conf" ]; then
        IFS=',' read -r -a __alloc_parts <<< "$raw_conf"
        for token in "${__alloc_parts[@]}"; do
            token="${token#"${token%%[![:space:]]*}"}"
            token="${token%"${token##*[![:space:]]}"}"
            [ -z "$token" ] && continue
            case "$token" in
                backend:*)
                    continue
                    ;;
                expandable_segments:*)
                    continue
                    ;;
                *)
                    if [ -n "$sanitized_conf" ]; then
                        sanitized_conf="${sanitized_conf},${token}"
                    else
                        sanitized_conf="${token}"
                    fi
                    ;;
            esac
        done
    fi

    if [ -n "$sanitized_conf" ]; then
        sanitized_conf="${sanitized_conf},expandable_segments:True"
    else
        sanitized_conf="expandable_segments:True"
    fi

    export PYTORCH_CUDA_ALLOC_CONF="$sanitized_conf"
    echo "Using PYTORCH_CUDA_ALLOC_CONF: $PYTORCH_CUDA_ALLOC_CONF"

}
