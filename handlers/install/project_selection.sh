# shellcheck shell=bash


project_selection_state_path() {
    echo "$NETWORK_VOLUME/.avatary_selected_project"
}


default_project_manifest_path() {
    echo "$SCRIPT_DIR/dependencies/avatary-image-generator-v1.yaml"
}


list_project_manifest_paths() {
    local dependencies_dir="$SCRIPT_DIR/dependencies"

    if [ ! -d "$dependencies_dir" ]; then
        echo "❌ Dependencies directory not found: $dependencies_dir"
        return 1
    fi

    local -a manifests=()
    local manifest_path
    while IFS= read -r manifest_path; do
        [ -n "$manifest_path" ] || continue
        manifests+=("$manifest_path")
    done < <(find "$dependencies_dir" -maxdepth 1 -type f -name '*.yaml' | LC_ALL=C sort)

    if [ "${#manifests[@]}" -eq 0 ]; then
        echo "❌ No dependency manifests found in $dependencies_dir"
        return 1
    fi

    PROJECT_MANIFEST_PATHS=("${manifests[@]}")
    return 0
}


manifest_project_key() {
    local manifest_path="$1"
    basename "$manifest_path" .yaml
}


save_selected_project_manifest() {
    local project_key="$1"
    local manifest_path="$2"
    local state_path
    state_path="$(project_selection_state_path)"

    mkdir -p "$NETWORK_VOLUME"
    printf '%s\t%s\n' "$project_key" "$manifest_path" > "$state_path"

    SELECTED_PROJECT_KEY="$project_key"
    SELECTED_PROJECT_MANIFEST_PATH="$manifest_path"
    INSTALL_MANIFEST_PATH="$manifest_path"
    export SELECTED_PROJECT_KEY SELECTED_PROJECT_MANIFEST_PATH INSTALL_MANIFEST_PATH
}


load_saved_project_manifest() {
    local state_path
    state_path="$(project_selection_state_path)"

    if [ ! -f "$state_path" ]; then
        return 1
    fi

    local saved_key=""
    local saved_path=""
    IFS=$'\t' read -r saved_key saved_path < "$state_path" || true

    if [ -z "$saved_key" ] || [ -z "$saved_path" ]; then
        echo "❌ Saved project selection is invalid: $state_path"
        return 1
    fi

    if [ ! -f "$saved_path" ]; then
        echo "❌ Saved dependency manifest is missing: $saved_path"
        return 1
    fi

    SAVED_PROJECT_KEY="$saved_key"
    SAVED_PROJECT_MANIFEST_PATH="$saved_path"
    export SAVED_PROJECT_KEY SAVED_PROJECT_MANIFEST_PATH
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
    IFS=$'\t' read -r saved_key saved_path < "$state_path" || true

    if [ -z "$saved_key" ] || [ -z "$saved_path" ]; then
        return 1
    fi

    if [ ! -f "$saved_path" ]; then
        return 1
    fi

    SAVED_PROJECT_KEY="$saved_key"
    SAVED_PROJECT_MANIFEST_PATH="$saved_path"
    export SAVED_PROJECT_KEY SAVED_PROJECT_MANIFEST_PATH
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


set_install_manifest_from_saved_project() {
    if ! load_saved_project_manifest; then
        echo "❌ No saved project selection found. Run 'bash start.sh' or 'bash start-new-project.sh' first."
        return 1
    fi

    INSTALL_MANIFEST_PATH="$SAVED_PROJECT_MANIFEST_PATH"
    SELECTED_PROJECT_KEY="$SAVED_PROJECT_KEY"
    SELECTED_PROJECT_MANIFEST_PATH="$SAVED_PROJECT_MANIFEST_PATH"
    export INSTALL_MANIFEST_PATH SELECTED_PROJECT_KEY SELECTED_PROJECT_MANIFEST_PATH

    echo "Using saved project: $SELECTED_PROJECT_KEY"
    return 0
}
