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

Run this command in the terminal to start ComfyUI. First step: enter your direct JSON URL `bash start.sh`

Run this command in the terminal to switch projects. First step: enter your direct JSON URL `bash start-new-project.sh`

Run this command in the terminal to add another project manifest without removing existing resources `bash add-project.sh`

Run this command in the terminal to replace current project resources with a new project manifest `bash replace-project.sh`

Run this command in the terminal to restart ComfyUI `bash restart-comfyui.sh`

Run this command in the terminal to update nodes and models (uses the last saved JSON URL) `bash update-nodes-and-models.sh`

Run this command in the terminal to list available commands `bash help.sh`

EOF
}
