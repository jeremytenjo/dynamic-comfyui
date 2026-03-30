#!/usr/bin/env bash

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for handler_file in "$SCRIPT_DIR"/handlers/install/*.sh; do
    # shellcheck source=/dev/null
    source "$handler_file"
done

NETWORK_VOLUME="/workspace"
export INSTALL_START_TS
INSTALL_START_TS=$(date +%s)

set_network_volume_default

if ! ensure_comfyui_workspace; then
    exit 1
fi

set_model_directories

if ! require_install_tools; then
    exit 1
fi

clear_install_sentinel

echo "Ensuring required custom nodes are installed through ComfyUI-Manager..."
if ! install_custom_nodes_with_manager; then
    echo "Custom node installation failed."
    exit 1
fi

echo "Installing required models with wget..."
if ! install_models_with_wget; then
    echo "Model installation failed."
    exit 1
fi

if ! ensure_required_text_encoders; then
    echo "Text encoder preflight failed."
    exit 1
fi

if ! ensure_required_vae_models; then
    echo "VAE preflight failed."
    exit 1
fi

write_install_sentinel

if ! start_comfyui_service; then
    exit 1
fi

echo "✅ Installation complete and ComfyUI is ready on port 8188."
