# shellcheck shell=bash


set_network_volume_default() {
    if [ ! -d "$NETWORK_VOLUME" ]; then
        echo "NETWORK_VOLUME directory '$NETWORK_VOLUME' does not exist. Using '/' as fallback."
        NETWORK_VOLUME="/"
    fi
    export NETWORK_VOLUME
}
