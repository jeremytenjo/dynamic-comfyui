# shellcheck shell=bash


verify_install_sentinel() {
    local sentinel="$NETWORK_VOLUME/.avatary_install_complete"
    [ -f "$sentinel" ]
}
