#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR"/handlers/shared/entrypoint_utils.sh

enable_tcmalloc_preload
source_start_handlers "$SCRIPT_DIR"
source_install_handlers "$SCRIPT_DIR"

# Set the network volume path
NETWORK_VOLUME="/workspace"

if ! prepare_network_volume_and_start_jupyter; then
    echo "❌ Failed to start JupyterLab. See /tmp/dynamic-comfyui-jupyter.log for details."
    exit 1
fi

set_network_volume_default
write_runtime_instructions

if ! ensure_comfyui_workspace; then
    exit 1
fi

enable_nodes_2_default
serve_setup_instructions_page

echo "Jupyter is running."
if verify_install_sentinel; then
    echo "Install marker found. Starting ComfyUI..."
    if ! start_comfyui_service; then
        echo "⚠️ Failed to auto-start ComfyUI. Run 'bash start.sh' from the Jupyter terminal."
    fi
fi

sleep infinity
