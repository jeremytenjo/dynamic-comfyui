#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREVIEW_DIR="$SCRIPT_DIR/local-setup-page-preview"
PORT="${1:-8189}"

if [ ! -f "$PREVIEW_DIR/index.html" ]; then
    echo "❌ Preview page not found: $PREVIEW_DIR/index.html"
    exit 1
fi

echo "Serving local setup-page preview at http://127.0.0.1:${PORT}"
echo "Press Ctrl+C to stop."
python3 -m http.server "$PORT" --directory "$PREVIEW_DIR"
