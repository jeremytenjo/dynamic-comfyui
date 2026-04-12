from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from urllib.request import Request, urlopen

LATEST_RELEASE_API_URL = "https://api.github.com/repos/jeremytenjo/dynamic-comfyui/releases/latest"
REEXEC_FLAG = "DYNAMIC_COMFYUI_RUNTIME_REEXECED"


def resolve_latest_runtime_wheel_url() -> str:
    req = Request(
        LATEST_RELEASE_API_URL,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "dynamic-comfyui-runtime-updater",
        },
    )
    with urlopen(req, timeout=20) as response:
        payload = json.loads(response.read().decode("utf-8"))

    assets = payload.get("assets", [])
    pattern = re.compile(r"^dynamic_comfyui_runtime-.+-py3-none-any\.whl$")
    for asset in assets:
        name = str(asset.get("name", ""))
        if pattern.match(name) and "-latest-" not in name:
            url = str(asset.get("browser_download_url", "")).strip()
            if url:
                return url

    available = ", ".join(str(asset.get("name", "")) for asset in assets) or "(none)"
    raise RuntimeError(f"Could not find a versioned runtime wheel asset in latest release. Assets: {available}")


def upgrade_runtime_package() -> bool:
    print("Updating dynamic-comfyui runtime package to latest release...")
    try:
        wheel_url = resolve_latest_runtime_wheel_url()
    except Exception as exc:
        print(f"Warning: could not resolve latest runtime wheel URL: {exc}")
        return False

    install = subprocess.run(
        [sys.executable, "-m", "pip", "install", "--no-cache-dir", "--upgrade", wheel_url]
    )
    if install.returncode != 0:
        print("Warning: failed to update runtime package from GitHub Releases.")
        return False
    print("Runtime package update complete.")
    return True


def uninstall_runtime_package() -> bool:
    print("Uninstalling dynamic-comfyui runtime package...")
    uninstall = subprocess.run([sys.executable, "-m", "pip", "uninstall", "-y", "dynamic-comfyui-runtime"])
    if uninstall.returncode != 0:
        print("Warning: failed to uninstall dynamic-comfyui-runtime package.")
        return False
    print("Runtime package uninstall complete.")
    return True


def upgrade_runtime_package_and_reexec_install() -> int:
    if os.environ.get(REEXEC_FLAG) == "1":
        return 0

    upgrade_runtime_package()
    env = os.environ.copy()
    env[REEXEC_FLAG] = "1"
    reexec = subprocess.run([sys.executable, "-m", "dynamic_comfyui_runtime.cli", "install"], env=env)
    return reexec.returncode
