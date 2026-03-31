# shellcheck shell=bash

install_custom_node_from_git() {
    local repo_dir="$1"
    local repo_url="$2"
    local pinned_version="$3"
    local node_path="$CUSTOM_NODES_DIR/$repo_dir"

    if [ -d "$node_path/.git" ]; then
        echo "🔄 Updating existing git node: $repo_dir"
        if ! git -C "$node_path" fetch --tags --prune origin; then
            echo "❌ Failed to fetch updates for custom node: $repo_dir"
            return 1
        fi
    elif [ -d "$node_path" ]; then
        echo "⚠️ Existing non-git directory found for $repo_dir; replacing it."
        if ! rm -rf "$node_path"; then
            echo "❌ Failed to remove existing custom node directory: $node_path"
            return 1
        fi
        if ! git clone "$repo_url" "$node_path"; then
            echo "❌ Failed to clone custom node repo: $repo_url"
            return 1
        fi
    else
        if ! git clone "$repo_url" "$node_path"; then
            echo "❌ Failed to clone custom node repo: $repo_url"
            return 1
        fi
    fi

    if [ -n "$pinned_version" ]; then
        if git -C "$node_path" rev-parse -q --verify "$pinned_version^{commit}" >/dev/null 2>&1; then
            if ! git -C "$node_path" checkout -q "$pinned_version"; then
                echo "❌ Failed to checkout pinned version $pinned_version for $repo_dir"
                return 1
            fi
        elif git -C "$node_path" rev-parse -q --verify "v$pinned_version^{commit}" >/dev/null 2>&1; then
            if ! git -C "$node_path" checkout -q "v$pinned_version"; then
                echo "❌ Failed to checkout pinned version v$pinned_version for $repo_dir"
                return 1
            fi
        else
            echo "❌ Pinned version not found in git repo for $repo_dir: $pinned_version"
            return 1
        fi
        echo "$pinned_version" > "$node_path/.cnr-version"
    fi

    return 0
}


install_custom_nodes() {
    local -a custom_node_specs=(
        "comfyui-manager|comfyui-manager|https://github.com/Comfy-Org/ComfyUI-Manager.git|3.0.1"
        "comfyui-rmbg|ComfyUI-RMBG|https://github.com/1038lab/ComfyUI-RMBG.git|3.0.0"
        "comfyui-inpaint-cropandstitch|ComfyUI-Inpaint-CropAndStitch|https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch.git|3.0.10"
        "ComfyUI-GGUF|ComfyUI-GGUF|https://github.com/city96/ComfyUI-GGUF.git|1.1.10"
        "comfyui-kjnodes|ComfyUI-KJNodes|https://github.com/kijai/ComfyUI-KJNodes.git|1.3.6"
        "comfyui-easy-use|ComfyUI-Easy-Use|https://github.com/yolain/ComfyUI-Easy-Use.git|1.3.6"
        "seedvr2_videoupscaler|ComfyUI-SeedVR2_VideoUpscaler|https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git|2.5.22"
        "comfyui_essentials|ComfyUI_essentials|https://github.com/cubiq/ComfyUI_essentials.git|1.1.0"
        "comfyui-joycaption|ComfyUI-JoyCaption|https://github.com/1038lab/ComfyUI-JoyCaption|2.0.2"
    )

    if ! ensure_comfy_cli_ready; then
        return 1
    fi

    if ! cd "$COMFYUI_DIR"; then
        echo "❌ Failed to cd into ComfyUI workspace: $COMFYUI_DIR"
        return 1
    fi

    local total_custom_nodes=${#custom_node_specs[@]}
    local custom_node_idx=0
    local custom_node_spec
    for custom_node_spec in "${custom_node_specs[@]}"; do
        local cnr_id
        local repo_dir
        local repo_url
        local pinned_version
        local comfy_output
        IFS='|' read -r cnr_id repo_dir repo_url pinned_version <<< "$custom_node_spec"
        custom_node_idx=$((custom_node_idx + 1))
        echo "⬇️ [$custom_node_idx/$total_custom_nodes] Installing $cnr_id via comfy-cli (target $repo_dir@$pinned_version)"

        comfy_output="$(comfy --workspace="$COMFYUI_DIR" node install "$cnr_id" 2>&1)"
        if [ $? -ne 0 ]; then
            if printf '%s' "$comfy_output" | grep -qiE "not found|@unknown|custom-node-list\.json"; then
                echo "⚠️ $cnr_id is not resolvable in comfy registry; falling back to git: $repo_url"
                if ! install_custom_node_from_git "$repo_dir" "$repo_url" "$pinned_version"; then
                    echo "❌ Failed to install custom node via git fallback: $repo_dir"
                    return 1
                fi
                continue
            fi

            echo "$comfy_output"
            echo "❌ Failed to install custom node via comfy-cli: $cnr_id"
            return 1
        fi

        local node_path="$CUSTOM_NODES_DIR/$repo_dir"
        if [ -d "$node_path" ]; then
            echo "$pinned_version" > "$node_path/.cnr-version"
        fi
    done

    return 0
}
