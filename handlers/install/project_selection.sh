# shellcheck shell=bash


project_selection_state_path() {
    echo "$NETWORK_VOLUME/.dynamic-comfyui_selected_project"
}


list_project_manifest_paths() {
    local runtime_projects_dir="${NETWORK_VOLUME:-/workspace}/projects"
    local -a candidate_dirs=("$runtime_projects_dir" "$SCRIPT_DIR/projects")
    local projects_dir=""
    local -a manifests=()
    local candidate_dir
    local manifest_path

    for candidate_dir in "${candidate_dirs[@]}"; do
        [ -d "$candidate_dir" ] || continue

        manifests=()
        while IFS= read -r manifest_path; do
            [ -n "$manifest_path" ] || continue
            manifests+=("$manifest_path")
        done < <(find "$candidate_dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | LC_ALL=C sort)

        if [ "${#manifests[@]}" -gt 0 ]; then
            projects_dir="$candidate_dir"
            break
        fi
    done

    if [ -z "$projects_dir" ] || [ "${#manifests[@]}" -eq 0 ]; then
        echo "❌ No project manifests found in $runtime_projects_dir or $SCRIPT_DIR/projects"
        return 1
    fi

    PROJECT_MANIFEST_PATHS=("${manifests[@]}")
    return 0
}


manifest_project_key() {
    local manifest_path="$1"
    local name
    name="$(basename "$manifest_path")"
    name="${name%.yaml}"
    name="${name%.yml}"
    printf '%s\n' "$name"
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


prompt_for_project_manifest_selection() {
    if ! list_project_manifest_paths; then
        return 1
    fi

    echo "Select Project:"

    local idx=0
    local manifest_path
    for manifest_path in "${PROJECT_MANIFEST_PATHS[@]}"; do
        idx=$((idx + 1))
        echo "  [$idx] $(manifest_project_key "$manifest_path")"
    done

    local selection=""
    while true; do
        read -r -p "Enter selection number: " selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#PROJECT_MANIFEST_PATHS[@]}" ]; then
            break
        fi

        echo "Invalid selection. Enter a number between 1 and ${#PROJECT_MANIFEST_PATHS[@]}."
    done

    local selected_path="${PROJECT_MANIFEST_PATHS[$((selection - 1))]}"
    local selected_key
    selected_key="$(manifest_project_key "$selected_path")"

    SELECTED_PROJECT_KEY="$selected_key"
    SELECTED_PROJECT_MANIFEST_PATH="$selected_path"
    export SELECTED_PROJECT_KEY SELECTED_PROJECT_MANIFEST_PATH

    return 0
}


load_saved_project_manifest_require_url() {
    if ! load_saved_project_manifest; then
        return 1
    fi

    if [ -z "${SAVED_PROJECT_SOURCE_URL:-}" ]; then
        echo "❌ Saved project selection is missing source URL (legacy state). Run 'bash start.sh' once."
        return 1
    fi

    return 0
}


set_install_manifest_from_saved_project() {
    if ! load_saved_project_manifest; then
        echo "❌ No saved project selection found. Run 'bash start.sh' or 'bash start-new-project.sh' first."
        return 1
    fi
    if [ -z "${SAVED_PROJECT_SOURCE_URL:-}" ]; then
        echo "❌ Saved project selection is missing source URL (legacy state). Run 'bash start.sh' once."
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
