#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR"/handlers/shared/entrypoint_utils.sh

enable_tcmalloc_preload
source_install_handlers "$SCRIPT_DIR"

NETWORK_VOLUME="/workspace"
export INSTALL_START_TS
INSTALL_START_TS=$(date +%s)
if ! prepare_manifest_install_context; then
    exit 1
fi

echo "Ensuring ComfyUI core workspace is installed..."
if ! install_comfyui_with_comfy_cli; then
    exit 1
fi

if ! cleanup_comfyui_invalid_backup; then
    exit 1
fi

clear_install_sentinel

if ! enable_comfyui_manager_modern_ui; then
    exit 1
fi

echo "Ensuring required custom nodes are installed via comfy-git..."
if ! install_custom_nodes; then
    echo "Custom node installation failed."
    exit 1
fi

echo "Installing required models with comfy-cli..."
if ! install_models_with_comfy_cli; then
    echo "Model installation failed."
    exit 1
fi

write_install_sentinel

if ! start_comfyui_service; then
    exit 1
fi

echo "✅ Installation complete and ComfyUI is ready on port 8188."
