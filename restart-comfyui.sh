#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR"/handlers/shared/entrypoint_utils.sh

enable_tcmalloc_preload
source_install_handlers "$SCRIPT_DIR"

NETWORK_VOLUME="${NETWORK_VOLUME:-/workspace}"
export NETWORK_VOLUME

set_network_volume_default

if ! ensure_comfyui_workspace; then
    echo "❌ Failed to prepare ComfyUI workspace."
    exit 1
fi

echo "Restarting ComfyUI..."
if ! start_comfyui_service; then
    echo "❌ Failed to restart ComfyUI."
    exit 1
fi

echo "✅ ComfyUI restart complete."
