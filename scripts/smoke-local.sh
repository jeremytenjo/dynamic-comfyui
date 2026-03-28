#!/usr/bin/env bash
set -euo pipefail

IMAGE_REF="${IMAGE_REF:-avatary-image-generator-v1:smoke-local}"
BUILD_PLATFORM="${BUILD_PLATFORM:-linux/amd64}"
SKIP_BUILD="${SKIP_BUILD:-0}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            IMAGE_REF="$2"
            shift 2
            ;;
        --platform)
            BUILD_PLATFORM="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD="1"
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

echo "==> Local smoke test"
echo "IMAGE_REF=$IMAGE_REF"
echo "BUILD_PLATFORM=$BUILD_PLATFORM"

if [[ "$SKIP_BUILD" != "1" ]]; then
    echo "==> Building image"
    docker build --platform "$BUILD_PLATFORM" -t "$IMAGE_REF" .
else
    echo "==> Skipping build (--skip-build)"
fi

echo "==> Running in-container checks"
docker run --rm --entrypoint /bin/bash "$IMAGE_REF" -lc '
set -euo pipefail

bash -n /start.sh

python3 - <<'"'"'PY'"'"'
import os
import sys

required_files = [
    "/start.sh",
    "/ComfyUI/main.py",
    "/ComfyUI/manager_requirements.txt",
]
missing = [p for p in required_files if not os.path.exists(p)]
if missing:
    print("Missing required files:", ", ".join(missing), file=sys.stderr)
    sys.exit(1)

print("Required files present.")
PY
'

echo "==> Smoke test passed."
