FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

ENV PYTHONUNBUFFERED=1
WORKDIR /

RUN apt-get update --yes && \
    DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
    git \
    curl \
    wget \
    zip \
    libgoogle-perftools4 && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade pip
RUN python3 -m pip install --no-cache-dir comfy-cli

RUN bash -lc 'set -euo pipefail; \
    PRELOAD_DIR="/opt/comfyui-preload"; \
    PRELOAD_PATH_FILE="/opt/comfyui-preload.path"; \
    mkdir -p "$PRELOAD_DIR"; \
    comfy_help="$(comfy --help 2>/dev/null || true)"; \
    install_help="$(comfy install --help 2>/dev/null || true)"; \
    extra_args=(); \
    if printf "%s" "$comfy_help" | grep -q -- "--skip-prompt"; then extra_args+=("--skip-prompt"); fi; \
    if printf "%s" "$comfy_help" | grep -q -- "--no-enable-telemetry"; then extra_args+=("--no-enable-telemetry"); fi; \
    comfy "${extra_args[@]}" tracking disable >/dev/null 2>&1 || true; \
    install_cmd=(comfy "${extra_args[@]}" --workspace="$PRELOAD_DIR" install); \
    if printf "%s" "$install_help" | grep -q -- "--nvidia"; then install_cmd+=("--nvidia"); fi; \
    "${install_cmd[@]}"; \
    resolved_workspace="$(comfy "${extra_args[@]}" --workspace="$PRELOAD_DIR" which 2>/dev/null | tail -n 1 | tr -d "\r" || true)"; \
    if [ -n "$resolved_workspace" ] && [ -d "$resolved_workspace" ]; then \
        printf "%s\n" "$resolved_workspace" > "$PRELOAD_PATH_FILE"; \
    elif [ -d "$PRELOAD_DIR/ComfyUI" ]; then \
        printf "%s\n" "$PRELOAD_DIR/ComfyUI" > "$PRELOAD_PATH_FILE"; \
    else \
        printf "%s\n" "$PRELOAD_DIR" > "$PRELOAD_PATH_FILE"; \
    fi'

COPY start.sh /start.sh
COPY install.sh /install.sh
COPY handlers /handlers

RUN chmod +x /start.sh /install.sh

EXPOSE 8188 8888

CMD ["/start.sh"]
