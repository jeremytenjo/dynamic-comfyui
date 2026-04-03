# shellcheck shell=bash

run_custom_node_post_install() {
    local repo_dir="$1"
    local node_path="$CUSTOM_NODES_DIR/$repo_dir"
    local requirements_file="$node_path/requirements.txt"
    local install_script="$node_path/install.py"

    if [ -f "$requirements_file" ]; then
        echo "📦 Installing Python requirements for $repo_dir"
        if ! python3 -m pip install --no-cache-dir -r "$requirements_file"; then
            echo "⚠️ Failed to install requirements for $repo_dir"
            return 1
        fi
    fi

    if [ -f "$install_script" ]; then
        echo "⚙️ Running install.py for $repo_dir"
        if ! (cd "$node_path" && python3 install.py); then
            echo "⚠️ install.py failed for $repo_dir"
            return 1
        fi
    fi

    return 0
}


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
        if ! run_custom_node_post_install "$repo_dir"; then
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

    if ! run_custom_node_post_install "$repo_dir"; then
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
    if ! read_nonempty_lines "$INSTALL_MANIFEST_CUSTOM_NODES_FILE"; then
        echo "❌ Failed to read custom node manifest entries: $INSTALL_MANIFEST_CUSTOM_NODES_FILE"
        return 1
    fi
    if [ "${READ_NONEMPTY_LINES_COUNT:-0}" -gt 0 ]; then
        custom_node_specs=("${READ_NONEMPTY_LINES[@]}")
    fi

    if [ "${#custom_node_specs[@]}" -eq 0 ]; then
        echo "No custom nodes defined in install manifest; skipping node installation."
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


print_installed_custom_nodes_summary() {
    print_installed_custom_nodes_summary_from_file "Installed custom nodes (default resources):" "${INSTALL_MANIFEST_DEFAULT_CUSTOM_NODES_FILE:-}"
    print_installed_custom_nodes_summary_from_file "Installed custom nodes (project manifest):" "${INSTALL_MANIFEST_PROJECT_CUSTOM_NODES_FILE:-}"
    return 0
}


print_installed_custom_nodes_summary_from_file() {
    local title="$1"
    local manifest_file="$2"

    echo "$title"
    if [ -z "$manifest_file" ] || [ ! -f "$manifest_file" ]; then
        echo " - (unavailable)"
        return 0
    fi

    local -a custom_node_specs=()
    if ! read_nonempty_lines "$manifest_file"; then
        echo " - (failed to read)"
        return 0
    fi
    if [ "${READ_NONEMPTY_LINES_COUNT:-0}" -gt 0 ]; then
        custom_node_specs=("${READ_NONEMPTY_LINES[@]}")
    fi

    if [ "${#custom_node_specs[@]}" -eq 0 ]; then
        echo " - (none)"
        return 0
    fi

    local spec
    for spec in "${custom_node_specs[@]}"; do
        local repo_dir
        local repo_url
        IFS=$'\t' read -r repo_dir repo_url <<< "$spec"
        if [ -d "$CUSTOM_NODES_DIR/$repo_dir" ]; then
            echo " - $repo_dir"
        else
            echo " - $repo_dir (missing on disk)"
        fi
    done

    return 0
}
