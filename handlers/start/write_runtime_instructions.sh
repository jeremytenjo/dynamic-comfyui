# shellcheck shell=bash

write_runtime_instructions() {
    local instructions_path="$NETWORK_VOLUME/instructions.txt"

    mkdir -p "$NETWORK_VOLUME"
    cat > "$instructions_path" <<'EOF'
Image Generator v1

Requirements:

L40S GPU

Usage: 

Run this command in the terminal to start ComfyUI `bash install.sh`

Run this command in the terminal to restart ComfyUI `bash restart-comfyui.sh`

EOF
}
