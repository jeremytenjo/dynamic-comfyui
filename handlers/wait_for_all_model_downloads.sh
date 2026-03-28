# shellcheck shell=bash


wait_for_all_model_downloads() {
    local failed_downloads=0
    local -a failed_items=()
    local i
    echo "Waiting for primary model downloads to complete..."
    for i in "${!PRIMARY_MODEL_DOWNLOAD_PIDS[@]}"; do
        local pid="${PRIMARY_MODEL_DOWNLOAD_PIDS[$i]}"
        local label="${PRIMARY_MODEL_DOWNLOAD_LABELS[$i]}"
        if ! wait "$pid"; then
            failed_downloads=$((failed_downloads + 1))
            failed_items+=("$label")
        fi
    done

    if [ "$failed_downloads" -gt 0 ]; then
        echo "❌ $failed_downloads model download task(s) failed."
        echo "Failed model download items:"
        local failed_item
        for failed_item in "${failed_items[@]}"; do
            echo " - $failed_item"
        done
        log_timing "installation" "model_downloads" "failed" "$INSTALL_START_TS" "$(date +%s)" "0" "model_downloads"
        return 1
    fi
    echo "All model downloads completed"
    return 0
}
