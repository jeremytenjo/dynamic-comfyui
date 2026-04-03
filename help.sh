#!/usr/bin/env bash

cat <<'TXT'
Dynamic ComfyUI Commands

- ComfyUI core version
  Managed at image build time via GitHub Action inputs (upgrade_comfyui/comfyui_version), not project JSON.

- bash start.sh
  Enter a direct JSON URL and install/start ComfyUI.

- bash start-new-project.sh
  Enter a new JSON URL and optionally clean previous project resources.

- bash add-project.sh
  Enter a new JSON URL and add missing nodes/models (keeps existing resources).

- bash replace-project.sh
  Enter a new JSON URL, remove previous project resources, then install/start new resources.

- bash update-nodes-and-models.sh
  Re-download the last saved JSON URL, refresh nodes/models, and restart ComfyUI.

- bash restart-comfyui.sh
  Restart ComfyUI service.

- bash help.sh
Show this help menu.
TXT
