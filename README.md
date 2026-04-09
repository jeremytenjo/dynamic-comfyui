# Dynamic ComfyUI Templates for RunPod

Define your files and custom nodes in templates for easy ComfyUI environment setup on RunPod.

## Usage

run `dc start` and follow the prompts.

## Commands

- `dc install`
  Start Jupyter/runtime boot flow for the pod. This is the container entry command.

- `dc start`
  Enter a JSON URL (or press Enter for defaults-only), then install/start ComfyUI.

- `dc start-new-project`
  Enter a new JSON URL (or press Enter for defaults-only) and optionally clean resources from the previously selected project.

- `dc add-project`
  Enter a new JSON URL (or press Enter for defaults-only) and add missing nodes/files without removing existing resources.

- `dc replace-project`
  Enter a new JSON URL (or press Enter for defaults-only), remove previous project resources, then reinstall/start the selected project resources.

- `dc update-nodes-and-models`
  Re-download the last saved JSON URL (or refresh defaults-only if URL is empty), refresh nodes/files, then restart ComfyUI. If the saved project manifest sets `require_huggingface_token: true`, you will be prompted for a token again.

- `dc restart`
  Restart ComfyUI service.

- `dc update-dc`
  Update the `dynamic-comfyui-runtime` package to the latest GitHub Release wheel.

- `dc help`
  Show the command help menu.

## Runtime Package (End to End)

`ComfyUI` core is still managed by Docker/GitHub Actions. Runtime logic is now implemented in Python modules, packaged as a pip wheel, and auto-updated at pod startup.

### What the runtime package contains

- Python runtime package: `dynamic_comfyui_runtime`.
- Python runtime modules under `src/dynamic_comfyui_runtime/runtime/` (install flow, manifest loading/merge, downloads, progress, ComfyUI service control).
- Python CLI entrypoint: `dc` with subcommands for install/start/project operations.

### How startup uses the package

On every container start, `dc install` does:

1. Resolves the latest runtime release from GitHub Releases API and selects the versioned wheel asset.
2. Runs `pip install --upgrade` using that versioned wheel URL.
3. Re-executes `dc install` from the updated package.
4. Runs the install/startup flow through Python runtime modules (no shell handler sourcing).
5. If package update fails, continues using the already-installed package version.

This keeps one Python command surface while allowing runtime updates without rebuilding the Docker image.

### Release a new runtime package

Prerequisites:

- `gh` CLI installed
- `gh auth login` completed
- `python3` available

Release flow:

1. Bump `[project].version` in `pyproject.toml`.
2. Run:
   `npm run deploy:patch` (or `deploy:minor` / `deploy:major`)

#### Deploy Script Behavior

- `deploy:*` enforces a clean git working tree before it runs.
- `deploy:*` bumps `pyproject.toml` version, commits that change, and pushes the current branch.
- After push succeeds, it publishes the runtime release assets for the new version.

What this script does:

- Builds the wheel from `pyproject.toml`.
- Creates two assets:
  - Versioned wheel (for example `dynamic_comfyui_runtime-0.1.0-py3-none-any.whl`)
  - Stable alias: `dynamic_comfyui_runtime-latest-py3-none-any.whl`
- Publishes assets to GitHub Release tag: `runtime-v<version>`.
  - Creates the release if it does not exist.
  - Writes release notes with a commit summary from the previous runtime tag to current `HEAD`.
  - Uploads with overwrite if it already exists.

### Runtime update behavior in pods

- New pods pull the latest runtime wheel during `dc install`.
- Existing running pods get the new runtime on next pod start cycle (when `dc install` runs again).
- You can also force a manual runtime package update in a running pod with `dc update-dc`.
- If GitHub is unreachable or install fails, startup continues with the currently installed Python runtime package.

### Debug Runtime In Jupyter Pod (No Docker Rebuild)

Use this workflow for runtime Python changes (`src/dynamic_comfyui_runtime/**`, CLI/runtime behavior, manifests, install flow):

1. Edit and test code locally in this repo.
2. Publish a new runtime wheel:
   `npm run deploy:patch` (or `deploy:minor` / `deploy:major`).
3. In the pod, open a Jupyter terminal and update runtime:
   `dc update-dc`
4. Re-run the flow you are testing, for example:
   - `dc start`
   - `dc update-nodes-and-models`
   - `dc restart`
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
- Rebuild/publish Docker images only when changing ComfyUI core/image-level dependencies (base image, system packages, Python runtime in image, or pinned ComfyUI core itself).

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
