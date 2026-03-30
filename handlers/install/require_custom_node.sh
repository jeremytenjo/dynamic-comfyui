# shellcheck shell=bash


require_custom_node() {
    local cnr_id="$1"
    local repo_dir="$2"
    local cnr_version="$3"
    if ! install_or_update_custom_node_cnr "$cnr_id" "$repo_dir" "$cnr_version"; then
        local end_ts
        end_ts=$(date +%s)
        echo "❌ Required custom node install/update failed: $repo_dir"
        log_timing "custom_node_install" "$repo_dir" "required_failed_abort" "$INSTALL_START_TS" "$end_ts" "0" "cnr:${cnr_id}@${cnr_version}"
        exit 1
    fi
}
