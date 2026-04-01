# Dynamic ComfyUI Templates for RunPod

Define your models and nodes in templates for easy ComfyUI environment management on RunPod.

## Template Format

Example (`projects/example.yaml`):

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

## YAML URL Flow

Runtime project loading uses a direct YAML URL:

- `bash start.sh` prompts for a YAML URL (`http(s)` and `.yaml`/`.yml`), downloads it, and installs from it.
- `bash start-new-project.sh` does the same prompt-first flow and keeps the optional previous-project cleanup prompt.
- `bash update-nodes-and-models.sh` re-downloads the last saved YAML URL and refreshes nodes/models.

The active downloaded manifest is stored at `/workspace/projects/active-project.yaml`.

## Main Commands

- `bash start.sh`
  Enter a YAML URL, then install/start ComfyUI.

- `bash start-new-project.sh`
  Enter a new YAML URL and optionally clean resources from the previously selected project.

- `bash update-nodes-and-models.sh`
  Re-download the last saved YAML URL, refresh nodes/models, then restart ComfyUI.
