from __future__ import annotations

import os
import subprocess
import sys

RUNTIME_WHEEL_URL = "https://github.com/jeremytenjo/dynamic-comfyui/releases/latest/download/dynamic_comfyui_runtime-latest-py3-none-any.whl"
REEXEC_FLAG = "DYNAMIC_COMFYUI_RUNTIME_REEXECED"


def upgrade_runtime_package() -> bool:
    print("Updating dynamic-comfyui runtime package to latest release...")
    install = subprocess.run(
        [sys.executable, "-m", "pip", "install", "--no-cache-dir", "--upgrade", RUNTIME_WHEEL_URL]
    )
    if install.returncode != 0:
        print("Warning: failed to update runtime package from GitHub Releases.")
        return False
    print("Runtime package update complete.")
    return True


def upgrade_runtime_package_and_reexec_install() -> int:
    if os.environ.get(REEXEC_FLAG) == "1":
        return 0

    upgrade_runtime_package()
    env = os.environ.copy()
    env[REEXEC_FLAG] = "1"
    reexec = subprocess.run([sys.executable, "-m", "dynamic_comfyui_runtime.cli", "install"], env=env)
    return reexec.returncode
