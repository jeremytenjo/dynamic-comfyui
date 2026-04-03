# shellcheck shell=bash


manifest_requires_huggingface_token() {
    if [ -z "${INSTALL_MANIFEST_PATH:-}" ]; then
        echo "❌ INSTALL_MANIFEST_PATH is not set. Cannot determine Hugging Face token requirements."
        return 1
    fi

    if [ ! -f "$INSTALL_MANIFEST_PATH" ]; then
        echo "❌ Install manifest file does not exist: $INSTALL_MANIFEST_PATH"
        return 1
    fi

    if ! python3 - "$INSTALL_MANIFEST_PATH" <<'PY'
import json
import sys
from pathlib import Path


path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"❌ Failed to parse install manifest JSON ({path}): {exc}", file=sys.stderr)
    raise SystemExit(1)

if data is None:
    data = {}

if not isinstance(data, dict):
    print("❌ Project manifest root must be a JSON object.", file=sys.stderr)
    raise SystemExit(1)

require_value = data.get("require_huggingface_token", False)
if not isinstance(require_value, bool):
    print("❌ Project manifest field 'require_huggingface_token' must be a boolean when provided.", file=sys.stderr)
    raise SystemExit(1)

print("1" if require_value else "0")
PY
    then
        return 1
    fi

    return 0
}


configure_manifest_huggingface_auth() {
    local requires_token=""

    requires_token="$(manifest_requires_huggingface_token)" || return 1

    if [ "$requires_token" = "1" ]; then
        local input_token=""
        echo "This project manifest requires a Hugging Face token for file downloads."
        read -r -p "Enter your Hugging Face token: " input_token
        if [ -z "$input_token" ]; then
            echo "❌ Hugging Face token is required by this project manifest. Aborting."
            return 1
        fi

        export REQUIRE_HUGGINGFACE_TOKEN=1
        export HF_TOKEN="$input_token"
        echo "Hugging Face token captured for this run."
    else
        export REQUIRE_HUGGINGFACE_TOKEN=0
        unset HF_TOKEN || true
    fi

    return 0
}
