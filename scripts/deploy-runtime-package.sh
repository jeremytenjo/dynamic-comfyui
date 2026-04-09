#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$#" -ne 1 ]; then
  echo "Usage: bash scripts/deploy-runtime-package.sh <patch|minor|major>"
  exit 1
fi

BUMP_TYPE="$1"
case "$BUMP_TYPE" in
  patch|minor|major) ;;
  *)
    echo "Invalid bump type: $BUMP_TYPE"
    echo "Expected one of: patch, minor, major"
    exit 1
    ;;
esac

cd "$REPO_ROOT"

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is not clean. Commit or stash changes before deploy."
  exit 1
fi

VERSION_LINE="$(grep -E '^version = "[0-9]+\.[0-9]+\.[0-9]+"$' pyproject.toml | head -n 1 || true)"
if [ -z "$VERSION_LINE" ]; then
  echo "Could not find semantic version in pyproject.toml"
  exit 1
fi

CURRENT_VERSION="${VERSION_LINE#version = \"}"
CURRENT_VERSION="${CURRENT_VERSION%\"}"

IFS='.' read -r MAJOR MINOR PATCH <<EOFV
$CURRENT_VERSION
EOFV

case "$BUMP_TYPE" in
  patch)
    PATCH=$((PATCH + 1))
    ;;
  minor)
    MINOR=$((MINOR + 1))
    PATCH=0
    ;;
  major)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    ;;
esac

NEXT_VERSION="${MAJOR}.${MINOR}.${PATCH}"
echo "Bumping runtime version: ${CURRENT_VERSION} -> ${NEXT_VERSION}"

python3 - "$NEXT_VERSION" <<'PY'
from pathlib import Path
import re
import sys

next_version = sys.argv[1]
path = Path("pyproject.toml")
text = path.read_text(encoding="utf-8")
updated, count = re.subn(
    r'^version = "[0-9]+\.[0-9]+\.[0-9]+"$',
    f'version = "{next_version}"',
    text,
    count=1,
    flags=re.MULTILINE,
)
if count != 1:
    raise SystemExit("Failed to update version in pyproject.toml")
path.write_text(updated, encoding="utf-8")
PY

if [ -z "$(git status --porcelain pyproject.toml)" ]; then
  echo "No version change detected in pyproject.toml"
  exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" = "HEAD" ]; then
  echo "Detached HEAD detected. Switch to a branch before deploy."
  exit 1
fi

git add pyproject.toml
git commit -m "chore(runtime): bump version to ${NEXT_VERSION}"
git push origin "$CURRENT_BRANCH"

bash scripts/release-runtime-package.sh
