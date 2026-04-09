# shellcheck shell=bash


install_manifest_tmp_dir() {
    printf '%s\n' "/tmp/dynamic-comfyui-install-manifest"
}

fetch_project_manifest() {
    local manifest_tmp_dir

    if [ -z "${INSTALL_MANIFEST_PATH:-}" ]; then
        echo "❌ INSTALL_MANIFEST_PATH is not set. Select a project with 'dynamic-comfyui start' or load a saved one first."
        return 1
    fi

    if [ ! -f "$INSTALL_MANIFEST_PATH" ]; then
        echo "❌ Install manifest file does not exist: $INSTALL_MANIFEST_PATH"
        return 1
    fi

    if [ ! -s "$INSTALL_MANIFEST_PATH" ]; then
        echo "❌ Install manifest is empty: $INSTALL_MANIFEST_PATH"
        return 1
    fi

    manifest_tmp_dir="$(install_manifest_tmp_dir)"
    if ! mkdir -p "$manifest_tmp_dir"; then
        echo "❌ Failed to create install manifest temp directory: $manifest_tmp_dir"
        return 1
    fi

    return 0
}
