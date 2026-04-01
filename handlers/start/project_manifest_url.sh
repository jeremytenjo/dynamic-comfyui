# shellcheck shell=bash


active_project_manifest_path() {
    echo "$NETWORK_VOLUME/projects/active-project.yaml"
}


validate_project_manifest_url() {
    local candidate_url="$1"
    if [[ "$candidate_url" =~ ^https?://.+\.(yaml|yml)(\?.*)?$ ]]; then
        return 0
    fi

    echo "❌ Invalid YAML URL. Expected HTTP(S) URL ending in .yaml or .yml"
    return 1
}


download_project_manifest_from_url() {
    local source_url="$1"
    local target_path="$2"

    mkdir -p "$(dirname "$target_path")"

    if ! curl --silent --show-error --fail --location "$source_url" --output "$target_path"; then
        echo "❌ Failed to download project manifest from URL: $source_url"
        return 1
    fi

    if [ ! -s "$target_path" ]; then
        echo "❌ Downloaded project manifest is empty: $target_path"
        return 1
    fi

    return 0
}


prompt_and_prepare_project_manifest_from_url() {
    local source_url=""
    local manifest_path
    manifest_path="$(active_project_manifest_path)"

    while true; do
        read -r -p "Enter project YAML URL: " source_url
        if [ -z "$source_url" ]; then
            echo "❌ YAML URL is required."
            continue
        fi

        if ! validate_project_manifest_url "$source_url"; then
            continue
        fi

        if ! download_project_manifest_from_url "$source_url" "$manifest_path"; then
            continue
        fi

        break
    done

    SELECTED_PROJECT_KEY="active-project"
    SELECTED_PROJECT_MANIFEST_PATH="$manifest_path"
    SELECTED_PROJECT_SOURCE_URL="$source_url"
    INSTALL_MANIFEST_PATH="$manifest_path"
    export SELECTED_PROJECT_KEY SELECTED_PROJECT_MANIFEST_PATH SELECTED_PROJECT_SOURCE_URL INSTALL_MANIFEST_PATH

    echo "Using manifest URL: $source_url"
    return 0
}


refresh_project_manifest_from_saved_url() {
    local state_path
    state_path="$(project_selection_state_path)"
    local manifest_path
    manifest_path="$(active_project_manifest_path)"
    local saved_key=""
    local saved_path=""
    local saved_source_url=""

    if [ ! -f "$state_path" ]; then
        echo "❌ No saved project selection found. Run 'bash start.sh' first."
        return 1
    fi

    IFS=$'\t' read -r saved_key saved_path saved_source_url < "$state_path" || true
    if [ -z "$saved_key" ] || [ -z "$saved_path" ]; then
        echo "❌ Saved project selection is invalid: $state_path"
        return 1
    fi
    if [ -z "$saved_source_url" ]; then
        echo "❌ Saved project selection is missing source URL (legacy state). Run 'bash start.sh' once."
        return 1
    fi

    if ! validate_project_manifest_url "$saved_source_url"; then
        echo "❌ Saved project URL is invalid. Run 'bash start.sh' and enter a valid YAML URL."
        return 1
    fi

    if ! download_project_manifest_from_url "$saved_source_url" "$manifest_path"; then
        return 1
    fi

    SELECTED_PROJECT_KEY="active-project"
    SELECTED_PROJECT_MANIFEST_PATH="$manifest_path"
    SELECTED_PROJECT_SOURCE_URL="$saved_source_url"
    INSTALL_MANIFEST_PATH="$manifest_path"
    export SELECTED_PROJECT_KEY SELECTED_PROJECT_MANIFEST_PATH SELECTED_PROJECT_SOURCE_URL INSTALL_MANIFEST_PATH

    save_selected_project_manifest "$SELECTED_PROJECT_KEY" "$SELECTED_PROJECT_MANIFEST_PATH" "$SELECTED_PROJECT_SOURCE_URL"
    return 0
}
