# shellcheck shell=bash


ensure_comfyui_workspace() {
    COMFYUI_DIR="$NETWORK_VOLUME/ComfyUI"
    CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"
    export COMFYUI_DIR CUSTOM_NODES_DIR

    if [ ! -d "$COMFYUI_DIR" ]; then
        mkdir -p "$NETWORK_VOLUME"
        if ! mv /ComfyUI "$COMFYUI_DIR"; then
            echo "Failed to move /ComfyUI into $COMFYUI_DIR"
            return 1
        fi
    else
        echo "Directory already exists, skipping move."
        if [ -d /ComfyUI ] && [ "$COMFYUI_DIR" != "/ComfyUI" ] && [ "$COMFYUI_DIR" != "//ComfyUI" ]; then
            if command -v rsync > /dev/null 2>&1; then
                rsync -au \
                    --exclude 'user/' \
                    --exclude 'models/' \
                    --exclude 'custom_nodes/' \
                    --exclude 'input/' \
                    --exclude 'output/' \
                    /ComfyUI/ "$COMFYUI_DIR"/
            else
                cp -au /ComfyUI/. "$COMFYUI_DIR"/
            fi
        fi
    fi

    mkdir -p "$CUSTOM_NODES_DIR"
    return 0
}
