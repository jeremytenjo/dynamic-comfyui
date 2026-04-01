# shellcheck shell=bash


prepare_manifest_install_context() {
    set_network_volume_default

    if ! load_install_manifest; then
        return 1
    fi

    if ! ensure_comfyui_workspace; then
        return 1
    fi

    set_model_directories

    if ! require_install_tools; then
        return 1
    fi

    return 0
}
