# Dynamic ComfyUI Templates for RunPod

Define project manifests (custom nodes + files) for repeatable ComfyUI setup on RunPod.

## Quick Start

1. Start project with the [Dynamic ComfyUI](https://console.runpod.io/deploy?template=8b30tcbyze) Runpod template.

2. Run `dc start` in the Jupyter terminal.

## Commands

- `dc install`
  Start Jupyter + runtime boot flow (container entry command).

- `dc install-deps`
  Install custom nodes/files only.
  Usage: `dc install-deps <project-json-url>` or `dc install-deps` (prompts for URL; Enter = defaults-only).
  ComfyUI workspace is auto-detected.
  This command does not start Jupyter or ComfyUI.

- `dc start`
  Enter a JSON URL (or press Enter for defaults-only), then install/start ComfyUI.

- `dc start-new-project`
  Enter a new JSON URL (or press Enter for defaults-only) and optionally remove previous project resources.

- `dc add-project`
  Enter a new JSON URL (or press Enter for defaults-only) and add missing nodes/files only.

- `dc replace-project`
  Enter a new JSON URL (or press Enter for defaults-only), remove previous project resources, then reinstall/start.

- `dc update-nodes-and-models`
  Re-download last saved project manifest (or defaults-only if empty), refresh nodes/files, then restart ComfyUI.
  If `require_huggingface_token: true`, you will be prompted for a token again.

- `dc restart`
  Restart ComfyUI service.

- `dc update-dc`
  Update the `dynamic-comfyui-runtime` package to the latest GitHub Release wheel.

- `dc uninstall-dc`
  Uninstall the `dynamic-comfyui-runtime` package from the current Python environment.

- `dc help`
  Show the command help menu.

### Startup Update Flow (`dc install`)

1. Resolves the latest runtime release from GitHub Releases API and selects the versioned wheel asset.
2. Runs `pip install --upgrade` using that versioned wheel URL.
3. Re-executes `dc install` from the updated package.
4. Runs install/startup through Python runtime modules.
5. If package update fails, continues using the already-installed package version.

### Updating Runtime In Pods

- New pods pull the latest runtime wheel during `dc install`.
- Existing running pods get the new runtime on next pod start cycle (when `dc install` runs again).
- You can force an immediate update in a running pod with `dc update-dc`.
- If GitHub is unreachable or install fails, startup continues with the currently installed Python runtime package.

### Debug Runtime In Jupyter Pod (No Docker Rebuild)

Use this workflow for runtime Python changes (`src/dynamic_comfyui_runtime/**`, CLI/runtime behavior, manifests, install flow):

1. Edit and test code locally in this repo.
2. Publish a new runtime wheel:
   `npm run deploy:patch` (or `deploy:minor` / `deploy:major`).
3. In the pod, open a Jupyter terminal and update runtime:
   `dc update-dc`
4. Re-run the command you are testing (for example `dc start`, `dc update-nodes-and-models`, or `dc restart`).
5. Iterate: make another code patch, publish again, run `dc update-dc` again in the same pod.

If the pod is on an older build where `dc update-dc` fails with an invalid wheel filename (`...-latest-py3-none-any.whl`), run this one-time bootstrap update:

```bash
WHEEL_URL="$(python3 - <<'PY'
import json, re, urllib.request
api = "https://api.github.com/repos/jeremytenjo/dynamic-comfyui/releases/latest"
req = urllib.request.Request(api, headers={"Accept":"application/vnd.github+json","User-Agent":"dc-bootstrap-updater"})
data = json.loads(urllib.request.urlopen(req, timeout=20).read().decode())
for a in data.get("assets", []):
    name = a.get("name", "")
    if re.match(r"^dynamic_comfyui_runtime-.+-py3-none-any\.whl$", name) and "-latest-" not in name:
        print(a["browser_download_url"])
        break
else:
    raise SystemExit("No versioned wheel found in latest release assets")
PY
)"
python3 -m pip install --no-cache-dir --upgrade "$WHEEL_URL"
```

After that bootstrap, `dc update-dc` will work for future updates.

### When Docker Rebuild Is Required

- Do **not** rebuild/publish Docker images for normal runtime Python changes.
- Rebuild/publish Docker images only when changing ComfyUI core or image-level dependencies (base image, apt/system packages, Python runtime in image, pinned ComfyUI core).

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

### Optional Hugging Face Token

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

When `require_huggingface_token` is `true`:

- The installer prompts for a Hugging Face token before installation.
- If the token is empty, installation stops immediately.
- The token is used only for that run and is not saved.
- Create a token at: https://huggingface.co/settings/tokens

## Default Resources (All Projects)

Global default resources are always fetched from:

- `https://github.com/jeremytenjo/dynamic-comfyui/blob/main/default-resources.json`

This URL is pinned in runtime code so pip-installed builds and source checkouts behave the same.

If the remote default manifest fails to download, the runtime falls back to local `default-resources.json` in this order: same directory as `package.json`, nearest parent directory from current working directory, then `/default-resources.json`. If none is available, install continues with project resources only (defaults skipped for that run, with a warning).

Default resources use the same schema as the project manifest format above.

## Usage in other RunPod Templates

```bash
python3 -m pip install --no-cache-dir --upgrade \
  "git+https://github.com/jeremytenjo/dynamic-comfyui.git"

dc install-deps <project-json-url>
```
