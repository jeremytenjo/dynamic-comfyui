# shellcheck shell=bash


run_comfyui_install_flow() {
    export INSTALL_START_TS
    INSTALL_START_TS=$(date +%s)

    if ! prepare_manifest_install_context; then
        setup_progress_mark_failed "Failed to prepare install context."
        return 1
    fi

    setup_progress_init

    echo "Ensuring ComfyUI core workspace is installed..."
    if ! install_comfyui_with_comfy_cli; then
        setup_progress_mark_failed "Failed to install ComfyUI core workspace."
        return 1
    fi

    if ! cleanup_comfyui_invalid_backup; then
        setup_progress_mark_failed "Failed to clean invalid ComfyUI backup."
        return 1
    fi

    clear_install_sentinel

    if ! enable_comfyui_manager_modern_ui; then
        setup_progress_mark_failed "Failed to enable ComfyUI manager UI."
        return 1
    fi

    echo "Ensuring required custom nodes are installed..."
    if ! install_custom_nodes; then
        setup_progress_mark_failed "Custom node installation failed."
        echo "Custom node installation failed."
        return 1
    fi
    print_installed_custom_nodes_summary

    echo "Installing required models..."
    if ! install_models_with_comfy_cli; then
        setup_progress_mark_failed "Model installation failed."
        echo "Model installation failed."
        return 1
    fi
    setup_progress_refresh
    print_installed_models_summary

    echo "Installing required files..."
    if ! install_files; then
        setup_progress_mark_failed "File installation failed."
        echo "File installation failed."
        return 1
    fi
    setup_progress_refresh
    print_installed_files_summary

    write_install_sentinel

    if ! start_comfyui_service; then
        setup_progress_mark_failed "Failed to start ComfyUI service."
        return 1
    fi

    setup_progress_mark_done
    print_installed_resources_summary

    echo "✅ Installation complete and ComfyUI is ready on port 8188."
    return 0
}
