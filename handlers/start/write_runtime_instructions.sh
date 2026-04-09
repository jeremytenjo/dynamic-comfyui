# shellcheck shell=bash

write_runtime_instructions() {
    local instructions_path="$NETWORK_VOLUME/instructions.txt"

    mkdir -p "$NETWORK_VOLUME"
    cat > "$instructions_path" <<'EOF'
Image Generator v1

Requirements:

L40S GPU

First Time Setup:

Save your character lora in the /ComfyUI/models/lora folder.

Usage: 

Run this command in the terminal to start ComfyUI. First step: enter your direct JSON URL `dynamic-comfyui start`

Run this command in the terminal to switch projects. First step: enter your direct JSON URL `dynamic-comfyui start-new-project`

Run this command in the terminal to add another project manifest without removing existing resources `dynamic-comfyui add-project`

Run this command in the terminal to replace current project resources with a new project manifest `dynamic-comfyui replace-project`

Run this command in the terminal to restart ComfyUI `dynamic-comfyui restart`

Run this command in the terminal to update nodes and files (uses the last saved JSON URL) `dynamic-comfyui update-nodes-and-models`

Run this command in the terminal to list available commands `dynamic-comfyui help`

EOF
}
