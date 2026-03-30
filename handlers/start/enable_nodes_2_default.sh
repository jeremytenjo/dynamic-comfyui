# shellcheck shell=bash


enable_nodes_2_default() {
    local settings_file="$NETWORK_VOLUME/ComfyUI/user/default/comfy.settings.json"
    mkdir -p "$(dirname "$settings_file")"

    python3 - "$settings_file" <<'PY'
import json
import os
import sys

settings_path = sys.argv[1]
settings = {}

if os.path.isfile(settings_path):
    try:
        with open(settings_path, "r", encoding="utf-8") as f:
            loaded = json.load(f)
            if isinstance(loaded, dict):
                settings = loaded
    except Exception:
        settings = {}

settings["Comfy.VueNodes.Enabled"] = True

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=4)
    f.write("\n")
PY

    echo "Enabled default Comfy setting: Comfy.VueNodes.Enabled=true"
}
