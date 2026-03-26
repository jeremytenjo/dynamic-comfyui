# Body-Gen Runpod Template

This repository is a Runpod template that boots a prepackaged ComfyUI setup, starts JupyterLab, downloads a baseline set of models, and launches ComfyUI with SageAttention enabled.

## What this template does

At pod startup, [start.sh](start.sh) runs and performs the full bootstrap flow:

1. Preloads `libtcmalloc` (if available) for better memory behavior.
2. Ensures `aria2` and `curl` are installed.
3. Builds and installs SageAttention in the background from a pinned commit.
4. Chooses a working root:
   - Uses `/workspace` when a network volume is mounted.
   - Falls back to `/` when no network volume is present.
5. Starts JupyterLab with no token/password on `0.0.0.0`.
6. Ensures ComfyUI exists at `<NETWORK_VOLUME>/ComfyUI`.
7. Installs `onnxruntime-gpu` in the background.
8. Downloads a predefined set of checkpoints, LoRAs, and upscalers from Hugging Face.
9. Optionally downloads extra models from CivitAI using environment variables.
10. Enables VideoHelperSuite latent preview defaults and writes ComfyUI-Manager config.
11. Waits for SageAttention build completion.
12. Starts ComfyUI with:

```bash
python3 <NETWORK_VOLUME>/ComfyUI/main.py --listen --use-sage-attention
```

## Repository layout

- [start.sh](start.sh): Main pod bootstrap and runtime script.
- [requirements.txt](requirements.txt): Python dependencies installed into the image.
- [ComfyUI](ComfyUI): Bundled ComfyUI source tree and custom node ecosystem.

## Deploy this template to Runpod

This section follows Runpod's custom template flow and adapts it to this repo.

Official guide:

- https://docs.runpod.io/pods/templates/create-custom-template

### 1) Prerequisites

- Runpod account
- Docker installed locally
- Docker Hub account

### 2) Create a Dockerfile in this repo

From this project root, create a `Dockerfile` similar to:

```dockerfile
FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

ENV PYTHONUNBUFFERED=1
WORKDIR /

# System deps used by start.sh and common custom nodes
RUN apt-get update --yes && \
  DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
    git curl aria2 && \
  rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --upgrade pip && \
  pip install --no-cache-dir -r /tmp/requirements.txt

COPY ComfyUI /ComfyUI
COPY start.sh /opt/template-start.sh
COPY run.sh /run.sh
RUN chmod +x /run.sh /opt/template-start.sh

# Keep base image services (Jupyter/SSH) and run our bootstrap flow
CMD ["/run.sh"]
```

Notes:

- `run.sh` starts Runpod base services first (including SSH), then runs `start.sh`.
- The Docker build excludes the editable `SageAttention` requirement; `start.sh` installs it at runtime from a pinned commit.
- The first boot can take time because models and SageAttention are downloaded/built.

### 3) Build locally

Use `linux/amd64` to match Runpod infra (important on Apple Silicon):

```bash
docker build --platform linux/amd64 -t YOUR_DOCKER_USERNAME/body-gen-comfyui:v1 .
```

Optional quick smoke test:

```bash
docker run --rm -it --platform linux/amd64 YOUR_DOCKER_USERNAME/body-gen-comfyui:v1 /bin/bash
```

### 4) Push image to Docker Hub

```bash
docker login
docker push YOUR_DOCKER_USERNAME/body-gen-comfyui:v1
```

Optional helper script for versioned publishes:

```bash
# Example: publish v1.2 to Docker Hub
tsx scripts/publish-dockerhub.ts v1.2 --username YOUR_DOCKER_USERNAME

# Also push :latest
tsx scripts/publish-dockerhub.ts v1.2 --username YOUR_DOCKER_USERNAME --latest

# Fast path: auto-bump from your last published version and push :latest
npm run publish:patch
```

Tips:

- The script stores your last successful values in `.publish-dockerhub.json` so you do not re-enter username/image each run.
- You can auto-bump semantic versions with `--bump patch|minor|major`.

### 5) Create the Runpod Pod Template

In Runpod Console:

1. Go to Templates -> New Template.
2. Set Container Image to `YOUR_DOCKER_USERNAME/body-gen-comfyui:v1`.

3. Container Disk: at least 30 GB recommended for this stack.
4. Add HTTP port `8188` (ComfyUI).
5. Add HTTP port `8888` (JupyterLab).
6. Add TCP port `22` (SSH).
7. Save Template.

If your Docker Hub repository is private, configure registry auth in the template:

1. Click `Select Registry Auth`.
2. Registry: `docker.io`.
3. Username: your Docker Hub username.
4. Password: your Docker Hub access token.
5. Save credentials and template.

Template reference used for this project:

- Name: `avatary-body-gen`
- Template ID: `aocbk7yxvz`

Optional environment variables:

- `CHECKPOINT_IDS_TO_DOWNLOAD`: comma-separated CivitAI model IDs
- `LORAS_IDS_TO_DOWNLOAD`: comma-separated CivitAI model IDs
- `NETWORK_VOLUME`: override persistent root path (default `/workspace`)
- `FORCE_SYNC_TEMPLATE=1`: re-seed missing ComfyUI files from image into volume on startup
- `UPDATE_COMFYUI_FROM_IMAGE=1`: update ComfyUI core files on the volume from image on startup (preserves `models`, `custom_nodes`, `user`, `input`, `output`, `temp`)

### 6) Deploy a Pod from the template

1. Go to Pods -> Deploy.
2. Choose template `avatary-body-gen` (`aocbk7yxvz`).
3. Select a GPU that matches your workload.
4. Attach the network volume `avatary-body-gen` for persistent models/workflows at `/workspace`.

- Volume URL: https://console.runpod.io/user/storage/i8zzrcicig

5. Ensure `SSH Terminal Access` is checked in deployment options.
6. Deploy.

### 7) Verify startup

- Wait until logs show ComfyUI is up.
- Open ComfyUI on port `8188`.
- Open JupyterLab on port `8888`.
- If needed, check:
  - `/workspace/comfyui_<RUNPOD_POD_ID>_nohup.log`
  - `/tmp/sage_build.log`
  - `/workspace/startup_timing.log` (or `/tmp/startup_timing.log` without network volume)

### 8) Versioning and updates

- Use versioned image tags (`v1`, `v1.1`, etc.) instead of `latest`.
- Rebuild and push a new tag for each template update.
- Update the Runpod template image tag when rolling out changes.

## Storage behavior

- Preferred persistent path: `/workspace`.
- Current development volume: `avatary-body-gen`.
- Volume details page: https://console.runpod.io/user/storage/i8zzrcicig
- If `/workspace` does not exist, runtime path changes to `/`.
- On first boot with a mounted network volume, the bundled `/ComfyUI` files are seeded once into `/workspace/ComfyUI` and tracked with a marker file.
- On later boots, the existing volume copy is reused to avoid expensive cross-filesystem moves (unless `UPDATE_COMFYUI_FROM_IMAGE=1` is set).
- On every boot with a mounted network volume, required workflow custom-node repos are ensured in `/workspace/ComfyUI/custom_nodes` if missing.
- Models and outputs are therefore stored under either:
  - `/workspace/ComfyUI/...` (persistent with network volume), or
  - `/ComfyUI/...` (ephemeral without network volume).

## Preloaded model downloads

The template auto-downloads a fixed baseline set into ComfyUI model folders:

- Checkpoints to `models/checkpoints`
- LoRAs to `models/loras`
- Upscalers to `models/upscale_models`

Downloads are done with `aria2c` in parallel and include simple corruption cleanup:

- Removes files smaller than 10 MB before re-download.
- Removes stale `.aria2` control files.
- Skips files that already exist with reasonable size.

## Optional CivitAI downloads via env vars

`start.sh` also supports dynamic model pulls via CivitAI IDs.

Use comma-separated IDs in these environment variables:

- `CHECKPOINT_IDS_TO_DOWNLOAD` -> downloaded to `ComfyUI/models/checkpoints`
- `LORAS_IDS_TO_DOWNLOAD` -> downloaded to `ComfyUI/models/loras`

If a value equals `replace_with_ids`, that category is skipped.

## Runtime services and ports

- ComfyUI: `8188`
- JupyterLab: default Jupyter port in the pod

The script probes `http://127.0.0.1:8188` to verify ComfyUI startup.

## Logs and diagnostics

- ComfyUI logs:
  - `/workspace/comfyui_<RUNPOD_POD_ID>_nohup.log` (or `/<...>` if no network volume)
- SageAttention build log:
  - `/tmp/sage_build.log`
- Startup timing log:
  - `/workspace/startup_timing.log` (or `/tmp/startup_timing.log` without network volume)
  - Includes per-boot timestamp, pod id, volume path, seed mode (`cold-seed`, `warm-reuse`, etc.), and total startup seconds.

If SageAttention fails, startup continues and ComfyUI is still launched.

## Security notes

JupyterLab is started with empty token/password and permissive CORS flags. This is convenient for private pod workflows but should be treated as an open surface if your pod/network exposure is broad.

## Customizing this template

Typical customizations happen in [start.sh](start.sh):

- Add/remove baseline model URLs.
- Change ComfyUI startup flags.
- Adjust preview/manager defaults.
- Add custom node setup steps.

For dependency updates, modify [requirements.txt](requirements.txt) and rebuild the template image.

## Quick mental model

Think of this template as:

1. Environment prep (system tools + Python deps)
2. Workspace selection (`/workspace` preferred)
3. Model and node bootstrap
4. ComfyUI launch and health check
5. Pod kept alive with `sleep infinity`
