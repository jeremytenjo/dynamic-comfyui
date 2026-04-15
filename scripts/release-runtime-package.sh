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
git fetch --tags --force >/dev/null 2>&1 || true

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
PREVIOUS_TAG="$(git tag --list 'runtime-v*' --sort=-v:refname | grep -Fxv "$TAG" | head -n 1 || true)"
REPO_FULL_NAME="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

build_release_notes() {
    local notes_file="$1"
    local range=""
    local changelog_line=""

    if [ -n "$PREVIOUS_TAG" ]; then
        range="${PREVIOUS_TAG}..HEAD"
        changelog_line="Full Changelog: https://github.com/${REPO_FULL_NAME}/compare/${PREVIOUS_TAG}...${TAG}"
    else
        range="HEAD"
        changelog_line="Full Changelog: Initial runtime release"
    fi

    {
        echo "## Summary"
        echo
        local commits
        commits="$(git log --no-merges --pretty='- %s (%h)' --invert-grep --grep='^chore(runtime): bump version to ' "$range")"
        if [ -n "$commits" ]; then
            echo "$commits"
        else
            echo "- No commit messages found for this runtime release."
        fi
        echo
        echo "$changelog_line"
    } >"$notes_file"
}

echo "Building runtime wheel for version: $RUNTIME_VERSION"
python3 -m pip install --upgrade pip build
rm -rf dist
python3 -m build --wheel

WHEEL_PATH="$(ls -1 dist/dynamic_comfyui_runtime-*.whl | head -n 1)"
LATEST_ALIAS_PATH="dist/dynamic_comfyui_runtime-latest-py3-none-any.whl"
cp "$WHEEL_PATH" "$LATEST_ALIAS_PATH"

RELEASE_NOTES_FILE="$(mktemp -t dynamic-comfyui-release-notes.XXXXXX.md)"
build_release_notes "$RELEASE_NOTES_FILE"

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG exists. Updating notes and uploading assets with overwrite..."
    gh release edit "$TAG" --title "$TAG" --notes-file "$RELEASE_NOTES_FILE"
    gh release upload "$TAG" dist/*.whl --clobber
else
    echo "Creating release $TAG with commit summary notes and uploading assets..."
    gh release create "$TAG" dist/*.whl --title "$TAG" --notes-file "$RELEASE_NOTES_FILE"
fi

rm -f "$RELEASE_NOTES_FILE"

echo "Runtime package release published: $TAG"
