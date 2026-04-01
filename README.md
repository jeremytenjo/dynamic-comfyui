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

## Settings Configuration

Project manifest sync requires `/workspace/settings.yaml` with `github.owner_url`:

```yaml
github:
  owner_url: 'https://github.com/<owner>/<repo>'
```

At runtime, `bash start.sh` and `bash start-new-project.sh` derive the source API from this URL and sync manifests from `projects` on branch `main`.

## Main Commands

- `bash start.sh`
  Select a project template and install/start ComfyUI.

- `bash start-new-project.sh`
  Switch to a different template and optionally clean resources from the previously selected project.

- `bash update-nodes-and-models.sh`
  Re-sync the currently selected project's nodes and models, then restart ComfyUI.
