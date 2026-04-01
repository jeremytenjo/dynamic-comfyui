# shellcheck shell=bash


install_sentinel_path() {
    echo "$NETWORK_VOLUME/.dynamic-comfyui_install_complete"
}


clear_install_sentinel() {
    local sentinel
    sentinel="$(install_sentinel_path)"
    rm -f "$sentinel"
}


write_install_sentinel() {
    local sentinel
    sentinel="$(install_sentinel_path)"
    cat > "$sentinel" <<EOF
installed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
comfyui_dir=$COMFYUI_DIR
EOF
    echo "✅ Wrote install sentinel: $sentinel"
}
