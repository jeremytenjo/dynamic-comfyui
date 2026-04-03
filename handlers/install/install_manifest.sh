# shellcheck shell=bash


load_install_manifest() {
    if ! fetch_project_manifest; then
        return 1
    fi

    local manifest_tmp_dir
    manifest_tmp_dir="$(install_manifest_tmp_dir)"
    rm -f \
        "$manifest_tmp_dir/custom_nodes.tsv" \
        "$manifest_tmp_dir/models.tsv" \
        "$manifest_tmp_dir/files.tsv" \
        "$manifest_tmp_dir/default_custom_nodes.tsv" \
        "$manifest_tmp_dir/project_custom_nodes.tsv" \
        "$manifest_tmp_dir/default_models.tsv" \
        "$manifest_tmp_dir/project_models.tsv" \
        "$manifest_tmp_dir/default_files.tsv" \
        "$manifest_tmp_dir/project_files.tsv"

    local default_nodes_manifest_path=""
    if [ -n "${SCRIPT_DIR:-}" ]; then
        default_nodes_manifest_path="$SCRIPT_DIR/default-resources.yaml"
    fi

    local handler_dir
    handler_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local manifest_parser_script
    manifest_parser_script="$handler_dir/manifest_resources.py"
    if [ ! -f "$manifest_parser_script" ]; then
        echo "❌ Manifest parser script not found: $manifest_parser_script"
        return 1
    fi

    local exports_output
    if ! exports_output="$(
        python3 "$manifest_parser_script" merge \
            --project-manifest "$INSTALL_MANIFEST_PATH" \
            --default-manifest "$default_nodes_manifest_path" \
            --out-dir "$manifest_tmp_dir"
    )"; then
        return 1
    fi

    eval "$exports_output"

    if [ ! -f "$INSTALL_MANIFEST_CUSTOM_NODES_FILE" ] || [ ! -f "$INSTALL_MANIFEST_MODELS_FILE" ] || [ ! -f "$INSTALL_MANIFEST_FILES_FILE" ] || \
        [ ! -f "$INSTALL_MANIFEST_DEFAULT_CUSTOM_NODES_FILE" ] || [ ! -f "$INSTALL_MANIFEST_PROJECT_CUSTOM_NODES_FILE" ] || \
        [ ! -f "$INSTALL_MANIFEST_DEFAULT_MODELS_FILE" ] || [ ! -f "$INSTALL_MANIFEST_PROJECT_MODELS_FILE" ] || \
        [ ! -f "$INSTALL_MANIFEST_DEFAULT_FILES_FILE" ] || [ ! -f "$INSTALL_MANIFEST_PROJECT_FILES_FILE" ]; then
        echo "❌ Manifest loader failed to generate normalized data files."
        return 1
    fi

    echo "Loaded install manifest: $INSTALL_MANIFEST_PATH"
    if [ -n "$default_nodes_manifest_path" ] && [ -f "$default_nodes_manifest_path" ]; then
        echo "Loaded default resources manifest: $default_nodes_manifest_path"
    fi
    return 0
}
