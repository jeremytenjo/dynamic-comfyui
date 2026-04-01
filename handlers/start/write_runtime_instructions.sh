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
Create /workspace/settings.yaml with github.owner_url pointing to your GitHub repo:
github:
  owner_url: "https://github.com/<owner>/<repo>"

Usage: 

Run this command in the terminal to start ComfyUI `bash start.sh`

Run this command in the terminal to switch projects `bash start-new-project.sh`

Run this command in the terminal to restart ComfyUI `bash restart-comfyui.sh`

Run this command in the terminal to update nodes and models `bash update-nodes-and-models.sh`

EOF
}
