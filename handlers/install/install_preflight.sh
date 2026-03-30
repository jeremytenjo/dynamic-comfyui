# shellcheck shell=bash


set_network_volume_default() {
    if [ ! -d "$NETWORK_VOLUME" ]; then
        echo "NETWORK_VOLUME directory '$NETWORK_VOLUME' does not exist. Using '/' as fallback."
        NETWORK_VOLUME="/"
    fi
    export NETWORK_VOLUME
}


set_model_directories() {
    DIFFUSION_MODELS_DIR="$COMFYUI_DIR/models/diffusion_models"
    TEXT_ENCODERS_DIR="$COMFYUI_DIR/models/text_encoders"
    VAE_DIR="$COMFYUI_DIR/models/vae"
    LORAS_DIR="$COMFYUI_DIR/models/loras"
    SEEDVR2_DIR="$COMFYUI_DIR/models/SEEDVR2"
    SAM3_DIR="$COMFYUI_DIR/models/sam3"
    export DIFFUSION_MODELS_DIR TEXT_ENCODERS_DIR VAE_DIR LORAS_DIR SEEDVR2_DIR SAM3_DIR

    mkdir -p \
        "$DIFFUSION_MODELS_DIR" \
        "$TEXT_ENCODERS_DIR" \
        "$VAE_DIR" \
        "$LORAS_DIR" \
        "$SEEDVR2_DIR" \
        "$SAM3_DIR"
}


require_install_tools() {
    local -a missing=()
    local tool

    for tool in python3 wget git; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "❌ Missing required install tools: ${missing[*]}"
        return 1
    fi

    return 0
}
