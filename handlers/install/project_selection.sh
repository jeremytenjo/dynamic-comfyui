# shellcheck shell=bash


project_selection_state_path() {
    echo "$NETWORK_VOLUME/.dynamic-comfyui_selected_project"
}

save_selected_project_manifest() {
    local project_key="$1"
    local manifest_path="$2"
    local project_source_url="${3:-}"
    local state_path
    state_path="$(project_selection_state_path)"

    mkdir -p "$NETWORK_VOLUME"
    printf '%s\t%s\t%s\n' "$project_key" "$manifest_path" "$project_source_url" > "$state_path"

    SELECTED_PROJECT_KEY="$project_key"
    SELECTED_PROJECT_MANIFEST_PATH="$manifest_path"
    SELECTED_PROJECT_SOURCE_URL="$project_source_url"
    INSTALL_MANIFEST_PATH="$manifest_path"
    export SELECTED_PROJECT_KEY SELECTED_PROJECT_MANIFEST_PATH SELECTED_PROJECT_SOURCE_URL INSTALL_MANIFEST_PATH
}


load_saved_project_manifest() {
    local state_path
    state_path="$(project_selection_state_path)"

    if [ ! -f "$state_path" ]; then
        return 1
    fi

    local saved_key=""
    local saved_path=""
    local saved_source_url=""
    IFS=$'\t' read -r saved_key saved_path saved_source_url < "$state_path" || true

    if [ -z "$saved_key" ] || [ -z "$saved_path" ]; then
        echo "❌ Saved project selection is invalid: $state_path"
        return 1
    fi

    if [ ! -f "$saved_path" ]; then
        echo "❌ Saved project manifest is missing: $saved_path"
        return 1
    fi

    SAVED_PROJECT_KEY="$saved_key"
    SAVED_PROJECT_MANIFEST_PATH="$saved_path"
    SAVED_PROJECT_SOURCE_URL="$saved_source_url"
    export SAVED_PROJECT_KEY SAVED_PROJECT_MANIFEST_PATH SAVED_PROJECT_SOURCE_URL
    return 0
}


try_load_saved_project_manifest() {
    local state_path
    state_path="$(project_selection_state_path)"

    if [ ! -f "$state_path" ]; then
        return 1
    fi

    local saved_key=""
    local saved_path=""
    local saved_source_url=""
    IFS=$'\t' read -r saved_key saved_path saved_source_url < "$state_path" || true

    if [ -z "$saved_key" ] || [ -z "$saved_path" ]; then
        return 1
    fi

    if [ ! -f "$saved_path" ]; then
        return 1
    fi

    SAVED_PROJECT_KEY="$saved_key"
    SAVED_PROJECT_MANIFEST_PATH="$saved_path"
    SAVED_PROJECT_SOURCE_URL="$saved_source_url"
    export SAVED_PROJECT_KEY SAVED_PROJECT_MANIFEST_PATH SAVED_PROJECT_SOURCE_URL
    return 0
}


set_install_manifest_from_saved_project() {
    if ! load_saved_project_manifest; then
        echo "❌ No saved project selection found. Run 'dynamic-comfyui start' or 'dynamic-comfyui start-new-project' first."
        return 1
    fi

    INSTALL_MANIFEST_PATH="$SAVED_PROJECT_MANIFEST_PATH"
    SELECTED_PROJECT_KEY="$SAVED_PROJECT_KEY"
    SELECTED_PROJECT_MANIFEST_PATH="$SAVED_PROJECT_MANIFEST_PATH"
    SELECTED_PROJECT_SOURCE_URL="$SAVED_PROJECT_SOURCE_URL"
    export INSTALL_MANIFEST_PATH SELECTED_PROJECT_KEY SELECTED_PROJECT_MANIFEST_PATH SELECTED_PROJECT_SOURCE_URL

    echo "Using saved project: $SELECTED_PROJECT_KEY"
    return 0
}
