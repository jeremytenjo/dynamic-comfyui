# shellcheck shell=bash


install_custom_node_from_git() {
    local repo_dir="$1"
    local repo_url="$2"
    local node_path="$CUSTOM_NODES_DIR/$repo_dir"

    if [ -d "$node_path/.git" ]; then
        echo "🔄 Updating existing git node: $repo_dir"
        if ! git -C "$node_path" pull --ff-only; then
            echo "⚠️ Failed to update custom node: $repo_dir"
            return 1
        fi
        return 0
    fi

    if [ -d "$node_path" ]; then
        echo "⚠️ Existing non-git directory found for $repo_dir; replacing it."
        if ! rm -rf "$node_path"; then
            echo "⚠️ Failed to remove existing custom node directory: $node_path"
            return 1
        fi
    fi

    if ! git clone "$repo_url" "$node_path"; then
        echo "⚠️ Failed to clone custom node repo: $repo_url"
        return 1
    fi

    return 0
}


install_custom_nodes() {
    if [ -z "${INSTALL_MANIFEST_CUSTOM_NODES_FILE:-}" ] || [ ! -f "$INSTALL_MANIFEST_CUSTOM_NODES_FILE" ]; then
        echo "❌ Manifest custom node data is missing. Ensure load_install_manifest ran successfully."
        return 1
    fi

    if ! cd "$COMFYUI_DIR"; then
        echo "❌ Failed to cd into ComfyUI workspace: $COMFYUI_DIR"
        return 1
    fi

    local -a custom_node_specs=()
    local node_line
    while IFS= read -r node_line; do
        [ -n "$node_line" ] || continue
        custom_node_specs+=("$node_line")
    done < "$INSTALL_MANIFEST_CUSTOM_NODES_FILE"

    if [ "${#custom_node_specs[@]}" -eq 0 ]; then
        echo "No custom nodes defined in dependencies manifest; skipping node installation."
        return 0
    fi

    local total_custom_nodes=${#custom_node_specs[@]}
    local node_idx=0
    local spec
    for spec in "${custom_node_specs[@]}"; do
        local repo_dir
        local repo_url
        IFS=$'\t' read -r repo_dir repo_url <<< "$spec"
        node_idx=$((node_idx + 1))
        echo "⬇️ [$node_idx/$total_custom_nodes] Installing git node $repo_dir"

        if ! install_custom_node_from_git "$repo_dir" "$repo_url"; then
            echo "❌ Custom node installation failed: $repo_dir"
            return 1
        fi
    done

    return 0
}
