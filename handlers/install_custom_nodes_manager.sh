# shellcheck shell=bash


ensure_manager_cli_available() {
    local manager_dir="$CUSTOM_NODES_DIR/comfyui-manager"
    local manager_repo="https://github.com/Comfy-Org/ComfyUI-Manager.git"
    local manager_cli="$manager_dir/cm-cli.py"

    if [ -f "$CUSTOM_NODES_DIR/ComfyUI-Manager/cm-cli.py" ] && [ ! -d "$manager_dir" ]; then
        mv "$CUSTOM_NODES_DIR/ComfyUI-Manager" "$manager_dir"
    fi

    if [ -d "$manager_dir/.git" ]; then
        git -C "$manager_dir" fetch --all --tags --prune
        git -C "$manager_dir" checkout --quiet main
        git -C "$manager_dir" pull --ff-only
    else
        rm -rf "$manager_dir"
        git clone "$manager_repo" "$manager_dir"
    fi

    if [ ! -f "$manager_cli" ]; then
        echo "❌ ComfyUI-Manager CLI not found at $manager_cli"
        return 1
    fi

    if [ -f "$manager_dir/requirements.txt" ]; then
        python3 -m pip install --no-cache-dir -r "$manager_dir/requirements.txt"
    fi

    export COMFY_MANAGER_CLI="$manager_cli"
    return 0
}


install_custom_nodes_with_manager() {
    if ! ensure_manager_cli_available; then
        return 1
    fi

    local -a custom_node_specs=(
        "was-ns|was-node-suite-comfyui|3.0.1"
        "comfyui-rmbg|ComfyUI-RMBG|3.0.0"
        "comfyui-inpaint-cropandstitch|ComfyUI-Inpaint-CropAndStitch|3.0.10"
        "ComfyUI-GGUF|ComfyUI-GGUF|1.1.10"
        "comfyui-kjnodes|ComfyUI-KJNodes|1.3.6"
        "comfyui-easy-use|ComfyUI-Easy-Use|1.3.6"
        "seedvr2_videoupscaler|ComfyUI-SeedVR2_VideoUpscaler|2.5.22"
        "comfyui_essentials|ComfyUI_essentials|1.1.0"
    )

    local total_custom_nodes=${#custom_node_specs[@]}
    local custom_node_idx=0
    local custom_node_spec
    for custom_node_spec in "${custom_node_specs[@]}"; do
        local cnr_id
        local repo_name
        local pinned_version
        IFS='|' read -r cnr_id repo_name pinned_version <<< "$custom_node_spec"
        custom_node_idx=$((custom_node_idx + 1))
        echo "⬇️ [$custom_node_idx/$total_custom_nodes] Installing $repo_name (target $cnr_id@$pinned_version)"
        if ! COMFYUI_PATH="$COMFYUI_DIR" python3 "$COMFY_MANAGER_CLI" install "$repo_name" --mode remote; then
            echo "❌ Failed to install custom node via ComfyUI-Manager: $repo_name"
            return 1
        fi
    done

    # Ensure post-install dependency hooks are executed for managed nodes.
    if ! COMFYUI_PATH="$COMFYUI_DIR" python3 "$COMFY_MANAGER_CLI" restore-dependencies; then
        echo "❌ Failed to restore custom node dependencies via ComfyUI-Manager"
        return 1
    fi

    return 0
}
