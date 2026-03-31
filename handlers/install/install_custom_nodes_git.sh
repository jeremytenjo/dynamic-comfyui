# shellcheck shell=bash


install_custom_nodes_with_comfy_cli() {
    local -a custom_node_specs=(
        "comfyui-manager|comfyui-manager|https://github.com/Comfy-Org/ComfyUI-Manager.git|3.0.1"
        "was-ns|was-node-suite-comfyui|https://github.com/WASasquatch/was-node-suite-comfyui.git|3.0.1"
        "comfyui-rmbg|ComfyUI-RMBG|https://github.com/1038lab/ComfyUI-RMBG.git|3.0.0"
        "comfyui-inpaint-cropandstitch|ComfyUI-Inpaint-CropAndStitch|https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch.git|3.0.10"
        "ComfyUI-GGUF|ComfyUI-GGUF|https://github.com/city96/ComfyUI-GGUF.git|1.1.10"
        "comfyui-kjnodes|ComfyUI-KJNodes|https://github.com/kijai/ComfyUI-KJNodes.git|1.3.6"
        "comfyui-easy-use|ComfyUI-Easy-Use|https://github.com/yolain/ComfyUI-Easy-Use.git|1.3.6"
        "seedvr2_videoupscaler|ComfyUI-SeedVR2_VideoUpscaler|https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git|2.5.22"
        "comfyui_essentials|ComfyUI_essentials|https://github.com/cubiq/ComfyUI_essentials.git|1.1.0"
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
        local unused_repo_url
        local pinned_version
        IFS='|' read -r cnr_id repo_dir unused_repo_url pinned_version <<< "$custom_node_spec"
        custom_node_idx=$((custom_node_idx + 1))
        echo "⬇️ [$custom_node_idx/$total_custom_nodes] Installing $cnr_id via comfy-cli (target $repo_dir@$pinned_version)"

        if ! comfy --workspace="$COMFYUI_DIR" node install "$cnr_id"; then
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
