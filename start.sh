#!/usr/bin/env bash

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for handler_file in "$SCRIPT_DIR"/handlers/*.sh; do
    # shellcheck source=/dev/null
    source "$handler_file"
done

# Set the network volume path
NETWORK_VOLUME="/workspace"

prepare_network_volume_and_start_jupyter

set_network_volume_default

if ! ensure_comfyui_workspace; then
    exit 1
fi

enable_nodes_2_default

echo "Jupyter is running."
if verify_install_sentinel; then
    echo "Install marker found. Run 'bash /install.sh' to ensure everything is up to date and start ComfyUI."
else
    echo "Run 'bash /install.sh' from the Jupyter terminal to install models/nodes and start ComfyUI."
fi

sleep infinity
