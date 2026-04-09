# shellcheck shell=bash


active_project_manifest_path() {
    echo "$NETWORK_VOLUME/projects/active-project.json"
}


normalize_project_manifest_url() {
    local candidate_url="$1"

    if [[ "$candidate_url" =~ ^https?://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$ ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        local ref="${BASH_REMATCH[3]}"
        local path="${BASH_REMATCH[4]}"
        printf 'https://raw.githubusercontent.com/%s/%s/%s/%s\n' "$owner" "$repo" "$ref" "$path"
        return 0
    fi

    printf '%s\n' "$candidate_url"
    return 0
}


validate_project_manifest_url() {
    local candidate_url="$1"
    if [[ "$candidate_url" =~ ^https?://.+\.json(\?.*)?$ ]]; then
        return 0
    fi

    echo "❌ Invalid JSON URL. Expected HTTP(S) URL ending in .json"
    return 1
}


download_project_manifest_from_url() {
    local source_url="$1"
    local target_path="$2"

    if ! curl_download_to_file "$source_url" "$target_path"; then
        echo "❌ Failed to download project manifest from URL: $source_url"
        return 1
    fi

    if [ ! -s "$target_path" ]; then
        echo "❌ Downloaded project manifest is empty: $target_path"
        return 1
    fi

    return 0
}


write_empty_project_manifest() {
    local target_path="$1"
    local target_dir
    target_dir="$(dirname "$target_path")"

    if ! mkdir -p "$target_dir"; then
        echo "❌ Failed to create manifest directory: $target_dir"
        return 1
    fi

    if ! printf '{}\n' > "$target_path"; then
        echo "❌ Failed to write empty project manifest: $target_path"
        return 1
    fi

    if [ ! -s "$target_path" ]; then
        echo "❌ Empty project manifest was not written: $target_path"
        return 1
    fi

    return 0
}


prompt_and_prepare_project_manifest_from_url() {
    local source_url=""
    local normalized_url=""
    local manifest_path
    manifest_path="$(active_project_manifest_path)"

    while true; do
        read -r -p "Enter project URL: " source_url
        if [ -z "$source_url" ]; then
            normalized_url=""
            if ! write_empty_project_manifest "$manifest_path"; then
                continue
            fi
            break
        fi

        normalized_url="$(normalize_project_manifest_url "$source_url")"

        if ! validate_project_manifest_url "$normalized_url"; then
            continue
        fi

        if ! download_project_manifest_from_url "$normalized_url" "$manifest_path"; then
            continue
        fi

        break
    done

    SELECTED_PROJECT_KEY="active-project"
    SELECTED_PROJECT_MANIFEST_PATH="$manifest_path"
    SELECTED_PROJECT_SOURCE_URL="$normalized_url"
    INSTALL_MANIFEST_PATH="$manifest_path"
    export SELECTED_PROJECT_KEY SELECTED_PROJECT_MANIFEST_PATH SELECTED_PROJECT_SOURCE_URL INSTALL_MANIFEST_PATH

    if [ -n "$SELECTED_PROJECT_SOURCE_URL" ]; then
        echo "Using manifest URL: $SELECTED_PROJECT_SOURCE_URL"
    else
        echo "Using defaults-only install (no project URL)."
    fi
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
        echo "❌ No saved project selection found. Run 'dynamic-comfyui start' first."
        return 1
    fi

    IFS=$'\t' read -r saved_key saved_path saved_source_url < "$state_path" || true
    if [ -z "$saved_key" ] || [ -z "$saved_path" ]; then
        echo "❌ Saved project selection is invalid: $state_path"
        return 1
    fi

    if [ -z "$saved_source_url" ]; then
        if ! write_empty_project_manifest "$manifest_path"; then
            return 1
        fi
    else
        saved_source_url="$(normalize_project_manifest_url "$saved_source_url")"
        if ! validate_project_manifest_url "$saved_source_url"; then
            echo "❌ Saved project URL is invalid. Run 'dynamic-comfyui start' and enter a valid JSON URL."
            return 1
        fi

        if ! download_project_manifest_from_url "$saved_source_url" "$manifest_path"; then
            return 1
        fi
    fi

    SELECTED_PROJECT_KEY="active-project"
    SELECTED_PROJECT_MANIFEST_PATH="$manifest_path"
    SELECTED_PROJECT_SOURCE_URL="$saved_source_url"
    INSTALL_MANIFEST_PATH="$manifest_path"
    export SELECTED_PROJECT_KEY SELECTED_PROJECT_MANIFEST_PATH SELECTED_PROJECT_SOURCE_URL INSTALL_MANIFEST_PATH

    save_selected_project_manifest "$SELECTED_PROJECT_KEY" "$SELECTED_PROJECT_MANIFEST_PATH" "$SELECTED_PROJECT_SOURCE_URL"
    return 0
}
