# Faster Docker + Runpod Test Loop

## Local smoke test (fast, no GPU)

```bash
make smoke-local
```

Or:

```bash
npm run smoke:local
```

This builds the image and validates:
- `/start.sh` shell syntax
- required runtime files inside the image

## Runpod GPU smoke test (real pod)

```bash
export RUNPOD_API_KEY=...
export RUNPOD_TEMPLATE_ID=...
export RUNPOD_GPU_TYPE_ID="NVIDIA L40S"
export RUNPOD_GPU_COUNT=1
export RUNPOD_CLOUD_TYPE=SECURE
# Optional immutable tag override:
export RUNPOD_IMAGE_NAME="tenjojeremy/avatary-image-generator-v1:sha-<commit>"

make smoke-runpod
```

Behavior:
- Creates a pod from your template.
- Waits for pod status `RUNNING`.
- Health-checks ComfyUI on `8188`.
- Auto-cleans pod at exit (set `RUNPOD_KEEP_POD=1` to keep it).

## GitHub workflows

- `.github/workflows/smoke-local.yml`
  - Docker-only smoke test on push/PR and manual dispatch.
- `.github/workflows/smoke-runpod.yml`
  - Manual Runpod GPU smoke test (`workflow_dispatch`).
  - Requires repository secret `RUNPOD_API_KEY`.
- `.github/workflows/docker-publish-manual.yml`
  - Publish-only workflow (separate from smoke tests).
