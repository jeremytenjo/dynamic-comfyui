# shellcheck shell=bash


run_comfyui_install_flow() {
    export INSTALL_START_TS
    INSTALL_START_TS=$(date +%s)

    if ! prepare_manifest_install_context; then
        return 1
    fi

    echo "Ensuring ComfyUI core workspace is installed..."
    if ! install_comfyui_with_comfy_cli; then
        return 1
    fi

    if ! cleanup_comfyui_invalid_backup; then
        return 1
    fi

    clear_install_sentinel

    if ! enable_comfyui_manager_modern_ui; then
        return 1
    fi

    echo "Ensuring required custom nodes are installed..."
    if ! install_custom_nodes; then
        echo "Custom node installation failed."
        return 1
    fi

    echo "Installing required models..."
    if ! install_models_with_comfy_cli; then
        echo "Model installation failed."
        return 1
    fi

    write_install_sentinel

    if ! start_comfyui_service; then
        return 1
    fi

    echo "✅ Installation complete and ComfyUI is ready on port 8188."
    return 0
}
