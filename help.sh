#!/usr/bin/env bash

cat <<'TXT'
Dynamic ComfyUI Commands

- ComfyUI core version
  Managed at image build time via GitHub Action inputs (upgrade_comfyui/comfyui_version), not project JSON.

- bash start.sh
  Enter a direct JSON URL (or press Enter for defaults-only) and install/start ComfyUI.

- bash start-new-project.sh
  Enter a new JSON URL (or press Enter for defaults-only) and optionally clean previous project resources.

- bash add-project.sh
  Enter a new JSON URL (or press Enter for defaults-only) and add missing nodes/files (keeps existing resources).

- bash replace-project.sh
  Enter a new JSON URL (or press Enter for defaults-only), remove previous project resources, then install/start new resources.

- bash update-nodes-and-models.sh
  Re-download the last saved JSON URL (or refresh defaults-only if URL is empty), refresh nodes/files, and restart ComfyUI.
  If the manifest sets require_huggingface_token=true, this command prompts for a token each run.

- bash restart-comfyui.sh
  Restart ComfyUI service.

- bash help.sh
Show this help menu.
TXT
