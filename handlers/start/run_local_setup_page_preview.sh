#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREVIEW_DIR="$SCRIPT_DIR/local-setup-page-preview"
DEFAULT_PORT=8188
PORT_INPUT="${1:-$DEFAULT_PORT}"
PORT="$DEFAULT_PORT"

if [[ "$PORT_INPUT" =~ ^[0-9]+$ ]] && [ "$PORT_INPUT" -ge 1 ] && [ "$PORT_INPUT" -le 65535 ]; then
    PORT="$PORT_INPUT"
else
    echo "⚠️ Invalid port '${PORT_INPUT}'. Falling back to ${DEFAULT_PORT}."
fi

if [ ! -f "$PREVIEW_DIR/index.html" ]; then
    echo "❌ Preview page not found: $PREVIEW_DIR/index.html"
    exit 1
fi

echo "Serving local setup-page preview at http://127.0.0.1:${PORT}"
echo "Press Ctrl+C to stop."
python3 -m http.server "$PORT" --directory "$PREVIEW_DIR"
