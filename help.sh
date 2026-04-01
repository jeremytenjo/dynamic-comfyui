#!/usr/bin/env bash

cat <<'TXT'
Dynamic ComfyUI Commands

- bash start.sh
  Enter a direct YAML URL and install/start ComfyUI.

- bash start-new-project.sh
  Enter a new YAML URL and optionally clean previous project resources.

- bash update-nodes-and-models.sh
  Re-download the last saved YAML URL, refresh nodes/models, and restart ComfyUI.

- bash restart-comfyui.sh
  Restart ComfyUI service.

- bash help.sh
Show this help menu.
TXT
