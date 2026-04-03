#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR"/handlers/shared/entrypoint_utils.sh

enable_tcmalloc_preload
source_start_handlers "$SCRIPT_DIR"
source_install_handlers "$SCRIPT_DIR"

NETWORK_VOLUME="/workspace"
export NETWORK_VOLUME

if ! refresh_project_manifest_from_saved_url; then
    exit 1
fi

if ! set_install_manifest_from_saved_project; then
    exit 1
fi

if ! prepare_manifest_install_context; then
    setup_progress_mark_failed "Failed to prepare install context."
    exit 1
fi

setup_progress_init

echo "Ensuring required custom nodes are installed..."
if ! install_custom_nodes; then
    setup_progress_mark_failed "Custom node refresh failed."
    echo "❌ Custom node refresh failed."
    exit 1
fi
print_installed_custom_nodes_summary

echo "Ensuring required models are installed..."
if ! install_models_with_comfy_cli; then
    setup_progress_mark_failed "Model refresh failed."
    echo "❌ Model refresh failed."
    exit 1
fi
setup_progress_refresh
print_installed_models_summary

echo "Ensuring required files are installed..."
if ! install_files; then
    setup_progress_mark_failed "File refresh failed."
    echo "❌ File refresh failed."
    exit 1
fi
setup_progress_refresh
print_installed_files_summary

echo "Node, model, and file refresh complete. Restarting ComfyUI..."
if ! bash /restart-comfyui.sh; then
    setup_progress_mark_failed "ComfyUI restart failed after refresh."
    echo "❌ Node/model refresh succeeded, but ComfyUI restart failed."
    exit 1
fi

setup_progress_mark_done
print_installed_resources_summary

echo "✅ Node, model, and file refresh complete. ComfyUI restarted."
