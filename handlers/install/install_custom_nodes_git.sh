# shellcheck shell=bash

install_custom_node_from_git() {
    local repo_dir="$1"
    local repo_url="$2"
    local pin_type="$3"
    local pin_value="$4"
    local node_path="$CUSTOM_NODES_DIR/$repo_dir"

    if [ -d "$node_path/.git" ]; then
        echo "🔄 Updating existing git node: $repo_dir"
        if ! git -C "$node_path" fetch --tags --prune origin; then
            echo "⚠️ Failed to fetch updates for custom node: $repo_dir"
            return 1
        fi
    elif [ -d "$node_path" ]; then
        echo "⚠️ Existing non-git directory found for $repo_dir; replacing it."
        if ! rm -rf "$node_path"; then
            echo "⚠️ Failed to remove existing custom node directory: $node_path"
            return 1
        fi
        if ! git clone "$repo_url" "$node_path"; then
            echo "⚠️ Failed to clone custom node repo: $repo_url"
            return 1
        fi
    else
        if ! git clone "$repo_url" "$node_path"; then
            echo "⚠️ Failed to clone custom node repo: $repo_url"
            return 1
        fi
    fi

    if [ -n "$pin_value" ]; then
        local resolved_ref="$pin_value"
        if [ "$pin_type" = "tag" ]; then
            if ! git -C "$node_path" rev-parse -q --verify "$resolved_ref^{commit}" >/dev/null 2>&1; then
                resolved_ref="v$pin_value"
            fi
        fi

        if ! git -C "$node_path" rev-parse -q --verify "$resolved_ref^{commit}" >/dev/null 2>&1; then
            echo "⚠️ Pinned $pin_type not found in git repo for $repo_dir: $pin_value"
            return 1
        fi
        if ! git -C "$node_path" checkout -q "$resolved_ref"; then
            echo "⚠️ Failed to checkout pinned $pin_type $resolved_ref for $repo_dir"
            return 1
        fi
        echo "$pin_value" > "$node_path/.cnr-version"
    fi

    return 0
}


install_custom_nodes() {
    if [ -z "${INSTALL_MANIFEST_CUSTOM_NODES_FILE:-}" ] || [ ! -f "$INSTALL_MANIFEST_CUSTOM_NODES_FILE" ]; then
        echo "❌ Manifest custom node data is missing. Ensure load_install_manifest ran successfully."
        return 1
    fi

    local -a custom_node_specs=()
    local node_line
    while IFS= read -r node_line; do
        [ -n "$node_line" ] || continue
        custom_node_specs+=("$node_line")
    done < "$INSTALL_MANIFEST_CUSTOM_NODES_FILE"

    if [ "${#custom_node_specs[@]}" -eq 0 ]; then
        echo "No custom nodes defined in install manifest; skipping node installation."
        return 0
    fi

    if ! ensure_comfy_cli_ready; then
        return 1
    fi

    if ! cd "$COMFYUI_DIR"; then
        echo "❌ Failed to cd into ComfyUI workspace: $COMFYUI_DIR"
        return 1
    fi

    local total_custom_nodes=${#custom_node_specs[@]}
    local max_parallel=4
    local -a custom_node_pids=()
    local -a custom_node_labels=()
    local custom_node_spec
    local custom_node_idx=0

    install_single_custom_node() {
        local spec="$1"
        local cnr_id
        local repo_dir
        local repo_url
        local pin_type
        local pin_value
        local comfy_output
        local used_git_fallback=0
        IFS=$'\t' read -r cnr_id repo_dir repo_url pin_type pin_value <<< "$spec"

        if [ -n "$cnr_id" ]; then
            comfy_output="$(comfy --workspace="$COMFYUI_DIR" node install "$cnr_id" 2>&1)"
            if [ $? -ne 0 ]; then
                if [ -n "$comfy_output" ]; then
                    echo "$comfy_output"
                fi
                echo "⚠️ comfy-cli install failed for $cnr_id; trying git fallback: $repo_url"
                if ! install_custom_node_from_git "$repo_dir" "$repo_url" "$pin_type" "$pin_value"; then
                    echo "⚠️ Git fallback failed for $repo_dir"
                    return 1
                fi
                used_git_fallback=1
            fi
        else
            if ! install_custom_node_from_git "$repo_dir" "$repo_url" "$pin_type" "$pin_value"; then
                echo "⚠️ Git install failed for $repo_dir"
                return 1
            fi
            used_git_fallback=1
        fi

        local node_path="$CUSTOM_NODES_DIR/$repo_dir"
        if [ "$used_git_fallback" -eq 0 ] && [ -d "$node_path" ]; then
            echo "$pin_value" > "$node_path/.cnr-version"
        fi

        return 0
    }

    for custom_node_spec in "${custom_node_specs[@]}"; do
        local cnr_id
        local repo_dir
        local repo_url
        local pin_type
        local pin_value
        IFS=$'\t' read -r cnr_id repo_dir repo_url pin_type pin_value <<< "$custom_node_spec"
        custom_node_idx=$((custom_node_idx + 1))
        if [ -n "$cnr_id" ]; then
            echo "⬇️ [$custom_node_idx/$total_custom_nodes] Queueing $cnr_id (target $repo_dir $pin_type:$pin_value)"
        else
            echo "⬇️ [$custom_node_idx/$total_custom_nodes] Queueing git node $repo_dir ($pin_type:$pin_value)"
        fi

        install_single_custom_node "$custom_node_spec" &
        custom_node_pids+=($!)
        custom_node_labels+=("${cnr_id:-$repo_dir}")

        if [ "${#custom_node_pids[@]}" -ge "$max_parallel" ]; then
            local wait_pid="${custom_node_pids[0]}"
            local wait_label="${custom_node_labels[0]}"
            if ! wait "$wait_pid"; then
                echo "❌ Custom node installation failed: $wait_label"
                return 1
            fi
            custom_node_pids=("${custom_node_pids[@]:1}")
            custom_node_labels=("${custom_node_labels[@]:1}")
        fi
    done

    local i
    for i in "${!custom_node_pids[@]}"; do
        local pid="${custom_node_pids[$i]}"
        local label="${custom_node_labels[$i]}"
        if ! wait "$pid"; then
            echo "❌ Custom node installation failed: $label"
            return 1
        fi
    done

    return 0
}
