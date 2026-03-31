#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR"/handlers/shared/entrypoint_utils.sh

enable_tcmalloc_preload
source_install_handlers "$SCRIPT_DIR"

NETWORK_VOLUME="/workspace"
export NETWORK_VOLUME

if ! prepare_manifest_install_context; then
    exit 1
fi

echo "Ensuring required custom nodes are installed via latest manifest..."
if ! install_custom_nodes; then
    echo "❌ Custom node refresh failed."
    exit 1
fi

echo "Ensuring required models are installed via latest manifest..."
if ! install_models_with_comfy_cli; then
    echo "❌ Model refresh failed."
    exit 1
fi

echo "Node and model refresh complete. Restarting ComfyUI..."
if ! bash /restart-comfyui.sh; then
    echo "❌ Node/model refresh succeeded, but ComfyUI restart failed."
    exit 1
fi

echo "✅ Node and model refresh complete. ComfyUI restarted."
