# Dynamic ComfyUI Templates for RunPod

Define your models and nodes in templates for easy ComfyUI environment setup on RunPod.

## Template Format

Example (`<URL>.yaml`):

```yaml
custom_nodes:
  - repo_dir: 'ComfyUI-Easy-Use'
    repo: 'https://github.com/yolain/ComfyUI-Easy-Use.git'

models:
  - url: 'https://huggingface.co/avatary-ai/files/resolve/main/ae.safetensors'
    target: 'models/vae/ae.safetensors'
```

## Commands

- `bash start.sh`
  Enter a YAML URL, then install/start ComfyUI.

- `bash start-new-project.sh`
  Enter a new YAML URL and optionally clean resources from the previously selected project.

- `bash add-project.sh`
  Enter a new YAML URL and add missing nodes/models without removing existing resources.

- `bash replace-project.sh`
  Enter a new YAML URL, remove previous project resources, then reinstall/start the selected project resources.

- `bash update-nodes-and-models.sh`
  Re-download the last saved YAML URL, refresh nodes/models, then restart ComfyUI.
