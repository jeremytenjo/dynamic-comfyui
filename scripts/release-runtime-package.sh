#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI (gh) is required. Install it and run 'gh auth login'."
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "GitHub CLI is not authenticated. Run 'gh auth login'."
    exit 1
fi

cd "$REPO_ROOT"

RUNTIME_VERSION="$(python3 - <<'PY'
from pathlib import Path
import tomllib

pyproject = Path('pyproject.toml')
data = tomllib.loads(pyproject.read_text(encoding='utf-8'))
print(data['project']['version'])
PY
)"

if [ -z "$RUNTIME_VERSION" ]; then
    echo "Could not read project version from pyproject.toml"
    exit 1
fi

TAG="runtime-v${RUNTIME_VERSION}"

echo "Building runtime wheel for version: $RUNTIME_VERSION"
python3 -m pip install --upgrade pip build
rm -rf dist
python3 -m build --wheel

WHEEL_PATH="$(ls -1 dist/dynamic_comfyui_runtime-*.whl | head -n 1)"
LATEST_ALIAS_PATH="dist/dynamic_comfyui_runtime-latest-py3-none-any.whl"
cp "$WHEEL_PATH" "$LATEST_ALIAS_PATH"

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG exists. Uploading assets with overwrite..."
    gh release upload "$TAG" dist/*.whl --clobber
else
    echo "Creating release $TAG and uploading assets..."
    gh release create "$TAG" dist/*.whl --title "$TAG" --generate-notes
fi

echo "Runtime package release published: $TAG"
