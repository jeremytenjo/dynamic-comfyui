#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR"/handlers/shared/entrypoint_utils.sh

enable_tcmalloc_preload
source_start_handlers "$SCRIPT_DIR"
source_install_handlers "$SCRIPT_DIR"

NETWORK_VOLUME="/workspace"
export NETWORK_VOLUME

if ! refresh_project_manifests; then
    exit 1
fi

if ! prompt_for_project_manifest_selection; then
    exit 1
fi

save_selected_project_manifest "$SELECTED_PROJECT_KEY" "$SELECTED_PROJECT_MANIFEST_PATH"
echo "Selected project: $SELECTED_PROJECT_KEY"

if ! run_comfyui_install_flow; then
    exit 1
fi
