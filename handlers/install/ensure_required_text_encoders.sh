# shellcheck shell=bash


ensure_required_text_encoders() {
    local missing=0
    local encoder_path=""
    local -a required_text_encoders=(
        "$TEXT_ENCODERS_DIR/qwen_3_4b.safetensors"
        "$TEXT_ENCODERS_DIR/Z-Image-AbliteratedV1.f16.gguf"
        "$TEXT_ENCODERS_DIR/Z-Image-AbliteratedV1.f16.safetensors"
        "$TEXT_ENCODERS_DIR/Qwen3-4b-Z-Image-Engineer-V4-F16.gguf"
    )

    for encoder_path in "${required_text_encoders[@]}"; do
        if [ ! -f "$encoder_path" ]; then
            echo "❌ Missing text encoder: $encoder_path"
            missing=$((missing + 1))
            continue
        fi

        local size_bytes
        size_bytes=$(stat -f%z "$encoder_path" 2>/dev/null || stat -c%s "$encoder_path" 2>/dev/null || echo 0)
        if [ "$size_bytes" -lt 10485760 ]; then
            echo "❌ Text encoder appears incomplete (<10MB): $encoder_path"
            missing=$((missing + 1))
        fi
    done

    if [ "$missing" -gt 0 ]; then
        log_timing "preflight" "text_encoders" "failed_missing_or_incomplete" "$INSTALL_START_TS" "$(date +%s)" "0" "$TEXT_ENCODERS_DIR"
        return 1
    fi

    log_timing "preflight" "text_encoders" "success" "$INSTALL_START_TS" "$(date +%s)" "0" "$TEXT_ENCODERS_DIR"
    return 0
}
