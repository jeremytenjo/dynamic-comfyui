# shellcheck shell=bash


capture_previous_project_state_for_switch() {
    PREVIOUS_PROJECT_KEY=""
    PREVIOUS_PROJECT_SOURCE_URL=""
    PREVIOUS_MANIFEST_SNAPSHOT_PATH=""

    if ! try_load_saved_project_manifest; then
        return 0
    fi

    PREVIOUS_PROJECT_KEY="$SAVED_PROJECT_KEY"
    PREVIOUS_PROJECT_SOURCE_URL="${SAVED_PROJECT_SOURCE_URL:-}"

    if [ -f "$SAVED_PROJECT_MANIFEST_PATH" ]; then
        PREVIOUS_MANIFEST_SNAPSHOT_PATH="$(mktemp /tmp/dynamic-comfyui-previous-project-manifest.XXXXXX.yaml)"
        cp -f "$SAVED_PROJECT_MANIFEST_PATH" "$PREVIOUS_MANIFEST_SNAPSHOT_PATH"
    fi

    export PREVIOUS_PROJECT_KEY PREVIOUS_PROJECT_SOURCE_URL PREVIOUS_MANIFEST_SNAPSHOT_PATH
    return 0
}


cleanup_previous_project_snapshot_file() {
    if [ -n "${PREVIOUS_MANIFEST_SNAPSHOT_PATH:-}" ] && [ -f "$PREVIOUS_MANIFEST_SNAPSHOT_PATH" ]; then
        rm -f "$PREVIOUS_MANIFEST_SNAPSHOT_PATH"
    fi
}


remove_previous_project_resources_and_reinstall_selected() {
    set_network_volume_default
    if ! ensure_comfyui_workspace; then
        return 1
    fi

    if [ -z "${PREVIOUS_MANIFEST_SNAPSHOT_PATH:-}" ] || [ ! -f "$PREVIOUS_MANIFEST_SNAPSHOT_PATH" ]; then
        echo "❌ Failed to locate previous manifest snapshot for cleanup."
        return 1
    fi

    echo "Removing resources from previous project: ${PREVIOUS_PROJECT_KEY:-unknown}"
    if ! remove_project_resources_from_manifest "$PREVIOUS_MANIFEST_SNAPSHOT_PATH"; then
        echo "❌ Failed to remove resources from previous project."
        return 1
    fi

    echo "Refreshing selected project resources after cleanup..."
    if ! prepare_manifest_install_context; then
        return 1
    fi
    if ! install_custom_nodes; then
        echo "❌ Failed to reinstall selected project custom nodes after cleanup."
        return 1
    fi
    print_installed_custom_nodes_summary
    if ! install_models_with_comfy_cli; then
        echo "❌ Failed to reinstall selected project models after cleanup."
        return 1
    fi
    print_installed_models_summary
    if ! install_files; then
        echo "❌ Failed to reinstall selected project files after cleanup."
        return 1
    fi
    print_installed_files_summary
    if ! start_comfyui_service; then
        return 1
    fi
    print_installed_resources_summary

    return 0
}
