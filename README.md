# Dynamic ComfyUI Templates for RunPod

Define your models and nodes in templates for easy ComfyUI environment setup on RunPod.

## Template Format

Example (`<URL>.json`):

```json
{
  "custom_nodes": [
    {
      "repo_dir": "ComfyUI-Easy-Use",
      "repo": "https://github.com/yolain/ComfyUI-Easy-Use.git"
    }
  ],
  "models": [
    {
      "url": "https://huggingface.co/avatary-ai/files/resolve/main/ae.safetensors",
      "target": "models/vae/ae.safetensors"
    }
  ],
  "files": [
    {
      "url": "https://example.com/config.json",
      "target": "custom_assets/config.json"
    }
  ]
}
```

## Default Resources (All Projects)

Global default resources are fetched from the URL configured in:

- `settings.json` (`default_resources_url`)

This lets you update defaults without rebuilding the image: edit the hosted JSON file at that URL.

If the remote default manifest fails to download, install continues with project resources only (defaults are skipped for that run, with a warning).

Manifest format:

```json
{
  "custom_nodes": [
    {
      "repo_dir": "example-node",
      "repo": "https://github.com/example/example-node.git"
    }
  ],
  "models": [
    {
      "url": "https://huggingface.co/example/model/resolve/main/example.safetensors",
      "target": "models/checkpoints/example.safetensors"
    }
  ],
  "files": [
    {
      "url": "https://example.com/config.json",
      "target": "custom_assets/config.json"
    }
  ]
}
```

## Commands

- `bash start.sh`
  Enter a JSON URL, then install/start ComfyUI.

- `bash start-new-project.sh`
  Enter a new JSON URL and optionally clean resources from the previously selected project.

- `bash add-project.sh`
  Enter a new JSON URL and add missing nodes/models/files without removing existing resources.

- `bash replace-project.sh`
  Enter a new JSON URL, remove previous project resources, then reinstall/start the selected project resources.

- `bash update-nodes-and-models.sh`
  Re-download the last saved JSON URL, refresh nodes/models/files, then restart ComfyUI.
