# Dynamic ComfyUI Templates for RunPod

This repository solves a specific setup problem:

Running ComfyUI on RunPod is easy to start, but hard to keep organized when each project needs different custom nodes and models.

This template system gives you a repeatable way to launch ComfyUI on RunPod while managing your own node/model stacks through predefined YAML templates in `dependencies/`.

## What This Solves

- Fast ComfyUI setup on RunPod without manually rebuilding each environment.
- Project-specific dependency management (custom nodes + models) in versioned YAML files.
- Easier switching between projects with different ComfyUI requirements.
- Simpler re-sync of nodes/models when templates change.

## How It Works

1. Define a project template in `dependencies/*.yaml`.
2. Start the environment and select a template.
3. The installer reads the template and installs the specified ComfyUI version, custom node repositories, and model files.
4. Your selected template is saved in `/workspace/.dynamic-comfyui_selected_project` for reuse.

## Template Format

Example (`dependencies/example.yaml`):

```yaml
comfyui_version: '0.18.2'

custom_nodes:
  - repo_dir: 'ComfyUI-Easy-Use'
    repo: 'https://github.com/yolain/ComfyUI-Easy-Use.git'

models:
  - url: 'https://huggingface.co/avatary-ai/files/resolve/main/ae.safetensors'
    target: 'models/vae/ae.safetensors'
```

Create one YAML file per project profile you want to maintain.

## Main Commands

- `bash start.sh`
  Select a project template and install/start ComfyUI.

- `bash start-new-project.sh`
  Switch to a different template and optionally clean dependencies from the previously selected project.

- `bash update-nodes-and-models.sh`
  Re-sync the currently selected project's nodes and models, then restart ComfyUI.

## Repo Structure

- `dependencies/`: predefined project templates (what to install)
- `handlers/`: modular install/start logic
- `install.sh`: container entrypoint that wires handlers together

## Summary

Use this repo when you want ComfyUI on RunPod, but still want full control of your own models and nodes in clean, predefined templates that are easier to download, reuse, and manage.
