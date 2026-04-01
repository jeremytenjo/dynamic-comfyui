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

previous_project_key=""
previous_manifest_path=""
if try_load_saved_project_manifest; then
    previous_project_key="$SAVED_PROJECT_KEY"
    previous_manifest_path="$SAVED_PROJECT_MANIFEST_PATH"
fi

if ! prompt_for_project_manifest_selection; then
    exit 1
fi

cleanup_previous_project_resources="no"
if [ -n "$previous_manifest_path" ] && [ "$previous_manifest_path" != "$SELECTED_PROJECT_MANIFEST_PATH" ]; then
    echo "Previous project: $previous_project_key"
    echo "Selected project: $SELECTED_PROJECT_KEY"
    while true; do
        read -r -p "Remove resources from previous project? (y/n): " remove_choice
        case "$remove_choice" in
            y|Y|yes|YES)
                cleanup_previous_project_resources="yes"
                break
                ;;
            n|N|no|NO)
                cleanup_previous_project_resources="no"
                break
                ;;
            *)
                echo "Invalid choice. Enter 'y' or 'n'."
                ;;
        esac
    done
fi

save_selected_project_manifest "$SELECTED_PROJECT_KEY" "$SELECTED_PROJECT_MANIFEST_PATH"
echo "Selected project: $SELECTED_PROJECT_KEY"

if ! run_comfyui_install_flow; then
    exit 1
fi

if [ "$cleanup_previous_project_resources" = "yes" ]; then
    set_network_volume_default
    if ! ensure_comfyui_workspace; then
        exit 1
    fi

    echo "Removing resources from previous project: $previous_project_key"
    if ! remove_project_resources_from_manifest "$previous_manifest_path"; then
        echo "❌ Failed to remove resources from previous project."
        exit 1
    fi

    echo "Refreshing selected project resources after cleanup..."
    if ! prepare_manifest_install_context; then
        exit 1
    fi
    if ! install_custom_nodes; then
        echo "❌ Failed to reinstall selected project custom nodes after cleanup."
        exit 1
    fi
    if ! install_models_with_comfy_cli; then
        echo "❌ Failed to reinstall selected project models after cleanup."
        exit 1
    fi
    if ! start_comfyui_service; then
        exit 1
    fi
fi
