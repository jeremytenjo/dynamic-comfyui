# shellcheck shell=bash


prepare_network_volume_and_start_jupyter() {
    # Check if NETWORK_VOLUME exists; if not, use root directory instead.
    if [ ! -d "$NETWORK_VOLUME" ]; then
        echo "NETWORK_VOLUME directory '$NETWORK_VOLUME' does not exist. You are NOT using a network volume. Setting NETWORK_VOLUME to '/' (root directory)."
        NETWORK_VOLUME="/"
        echo "NETWORK_VOLUME directory doesn't exist. Starting JupyterLab on root directory..."
        jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/ &
    else
        echo "NETWORK_VOLUME directory exists. Starting JupyterLab..."
        jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/workspace &
    fi
}
