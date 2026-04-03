# Dynamic ComfyUI Templates for RunPod

Define your files and custom nodes in templates for easy ComfyUI environment setup on RunPod.

## Commands

- `bash start.sh`
  Enter a JSON URL (or press Enter for defaults-only), then install/start ComfyUI.

- `bash start-new-project.sh`
  Enter a new JSON URL (or press Enter for defaults-only) and optionally clean resources from the previously selected project.

- `bash add-project.sh`
  Enter a new JSON URL (or press Enter for defaults-only) and add missing nodes/files without removing existing resources.

- `bash replace-project.sh`
  Enter a new JSON URL (or press Enter for defaults-only), remove previous project resources, then reinstall/start the selected project resources.

- `bash update-nodes-and-models.sh`
  Re-download the last saved JSON URL (or refresh defaults-only if URL is empty), refresh nodes/files, then restart ComfyUI. If the saved project manifest sets `require_huggingface_token: true`, you will be prompted for a token again.

## Project File Format

Example (`<URL>.json`):

```json
{
  "require_huggingface_token": false,
  "custom_nodes": [
    {
      "repo_dir": "ComfyUI-Easy-Use",
      "repo": "https://github.com/yolain/ComfyUI-Easy-Use.git"
    }
  ],
  "files": [
    {
      "url": "https://huggingface.co/avatary-ai/files/resolve/main/ae.safetensors",
      "target": "models/vae/ae.safetensors"
    },
    {
      "url": "https://example.com/config.json",
      "target": "custom_assets/config.json"
    }
  ]
}
```

### Optional Hugging Face Token Requirement

Project manifests can require a Hugging Face token for file downloads:

```json
{
  "require_huggingface_token": true,
  "files": [
    {
      "url": "https://huggingface.co/example/private-model/resolve/main/model.safetensors",
      "target": "models/checkpoints/model.safetensors"
    }
  ]
}
```

Behavior when `require_huggingface_token` is `true`:

- The installer prompts for a Hugging Face token before installation.
- If the token is empty, installation stops immediately.
- The token is used only for that run and is not saved.
- Create a token at: https://huggingface.co/settings/tokens

## Default Resources (All Projects)

Global default resources are fetched from the URL configured in:

- `package.json` (`default_resources_url`)

This lets you update defaults without rebuilding the image: edit the hosted JSON file at that URL.

If the remote default manifest fails to download, install continues with project resources only (defaults are skipped for that run, with a warning).

Manifest format:

```json
{
  "require_huggingface_token": false,
  "custom_nodes": [
    {
      "repo_dir": "example-node",
      "repo": "https://github.com/example/example-node.git"
    }
  ],
  "files": [
    {
      "url": "https://huggingface.co/example/model/resolve/main/example.safetensors",
      "target": "models/checkpoints/example.safetensors"
    },
    {
      "url": "https://example.com/config.json",
      "target": "custom_assets/config.json"
    }
  ]
}
```
