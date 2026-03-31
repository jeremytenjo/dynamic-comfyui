# shellcheck shell=bash

enable_comfyui_manager_modern_ui() {
    if ! ensure_comfy_cli_ready; then
        return 1
    fi

    echo "Enabling ComfyUI-Manager modern UI..."
    if ! comfy --workspace="$COMFYUI_DIR" manager enable-gui; then
        echo "❌ Failed to enable ComfyUI-Manager modern UI."
        return 1
    fi

    return 0
}
