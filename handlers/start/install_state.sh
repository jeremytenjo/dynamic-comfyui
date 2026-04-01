# shellcheck shell=bash


verify_install_sentinel() {
    local sentinel="$NETWORK_VOLUME/.dynamic-comfyui_install_complete"
    [ -f "$sentinel" ]
}
