# shellcheck shell=bash


install_manifest_tmp_dir() {
    printf '%s\n' "/tmp/avatary-install-manifest"
}

set_install_manifest_path_default() {
    if [ -z "${INSTALL_MANIFEST_PATH:-}" ]; then
        local default_manifest
        default_manifest="$(default_project_manifest_path)"
        if [ -f "$default_manifest" ]; then
            INSTALL_MANIFEST_PATH="$default_manifest"
            export INSTALL_MANIFEST_PATH
        fi
    fi
}


fetch_dependencies() {
    local manifest_tmp_dir

    set_install_manifest_path_default

    if [ -z "${INSTALL_MANIFEST_PATH:-}" ]; then
        echo "❌ INSTALL_MANIFEST_PATH is not set."
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
