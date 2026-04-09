from __future__ import annotations

import os
import re
import shutil
import subprocess
import time
from pathlib import Path
from urllib.parse import urlparse, urlunparse

from .common import (
    command_exists,
    configure_tcmalloc_preload,
    ensure_dir,
    is_http_reachable,
    run,
    sanitize_torch_cuda_alloc_conf,
)
from .progress import stop_setup_page_server


def set_network_volume_default(network_volume: Path) -> Path:
    if network_volume.is_dir():
        return network_volume
    print(f"NETWORK_VOLUME directory '{network_volume}' does not exist. Using '/' as fallback.")
    return Path("/")


def ensure_comfyui_workspace(network_volume: Path) -> tuple[Path, Path]:
    comfyui_dir = network_volume / "ComfyUI"
    custom_nodes_dir = comfyui_dir / "custom_nodes"
    ensure_dir(network_volume)

    root_comfy = Path("/ComfyUI")
    if not comfyui_dir.is_dir() and root_comfy.is_dir() and not root_comfy.is_symlink():
        print(f"Moving image ComfyUI workspace to persistent volume: {comfyui_dir}")
        shutil.move(str(root_comfy), str(comfyui_dir))

    if comfyui_dir.is_dir():
        ensure_dir(custom_nodes_dir)

    if root_comfy.is_symlink():
        current = os.readlink(root_comfy)
        if current != str(comfyui_dir):
            root_comfy.unlink(missing_ok=True)
            root_comfy.symlink_to(comfyui_dir)
    elif not root_comfy.exists() and comfyui_dir.is_dir():
        root_comfy.symlink_to(comfyui_dir)

    return comfyui_dir, custom_nodes_dir


def set_model_directories(comfyui_dir: Path) -> None:
    for rel in (
        "models/diffusion_models",
        "models/text_encoders",
        "models/vae",
        "models/loras",
        "models/SEEDVR2",
        "models/sam3",
    ):
        ensure_dir(comfyui_dir / rel)


def _install_comfy_cli(network_volume: Path) -> None:
    pip_cmd = ["python3", "-m", "pip", "install", "--no-cache-dir", "comfy-cli"]
    if network_volume != Path("/") and network_volume.is_dir() and os.access(network_volume, os.W_OK):
        cache_dir = network_volume / ".cache" / "pip"
        ensure_dir(cache_dir)
        pip_cmd = ["python3", "-m", "pip", "install", "--cache-dir", str(cache_dir), "comfy-cli"]
    run(pip_cmd)


def ensure_comfy_cli_ready(network_volume: Path) -> None:
    if not command_exists("comfy"):
        print("Installing comfy-cli...")
        _install_comfy_cli(network_volume)
    if not command_exists("comfy"):
        raise RuntimeError("comfy-cli installation completed but 'comfy' command is not available")
    # This command is best-effort; do not block runtime setup on telemetry config.
    try:
        run(["comfy", "tracking", "disable"], check=False, quiet=True, timeout=20, input_text="n\n")
    except Exception as exc:
        print(f"Warning: comfy tracking disable skipped: {exc}")


def verify_comfyui_core_workspace(comfyui_dir: Path) -> None:
    valid = (
        (comfyui_dir / ".git").is_dir()
        and (comfyui_dir / "main.py").is_file()
        and (comfyui_dir / "custom_nodes").is_dir()
        and (comfyui_dir / "models").is_dir()
    )
    if not valid:
        raise RuntimeError(
            f"ComfyUI core workspace is missing or invalid at {comfyui_dir}. Rebuild the image to change core version."
        )


def enable_manager_gui(comfyui_dir: Path) -> None:
    print("Enabling ComfyUI-Manager modern UI...")
    run(["comfy", "--workspace", str(comfyui_dir), "manager", "enable-gui"], timeout=30, input_text="n\n")


def _ensure_manager_runtime_ready(comfyui_dir: Path, network_volume: Path) -> None:
    manager_reqs = comfyui_dir / "manager_requirements.txt"
    if not manager_reqs.is_file():
        raise RuntimeError(f"Missing manager requirements file: {manager_reqs}")

    pip_cmd = ["python3", "-m", "pip", "install", "--no-cache-dir", "-r", str(manager_reqs)]
    if network_volume != Path("/") and network_volume.is_dir() and os.access(network_volume, os.W_OK):
        cache_dir = network_volume / ".cache" / "pip"
        ensure_dir(cache_dir)
        pip_cmd = ["python3", "-m", "pip", "install", "--cache-dir", str(cache_dir), "-r", str(manager_reqs)]
    run(pip_cmd)

    if not command_exists("cm-cli"):
        run(["python3", "-m", "pip", "install", "--no-cache-dir", "comfyui-manager"], check=False)


def _apply_flash_attn_runtime_hotfix() -> None:
    hotfix_dir = Path("/tmp/comfy_python_hotfixes")
    ensure_dir(hotfix_dir)
    sitecustomize = hotfix_dir / "sitecustomize.py"
    sitecustomize.write_text(
        """
try:
    from transformers.utils import import_utils as _iu  # type: ignore
    _flash_keys = {\"flash_attn\", \"flash-attn\"}
    for _name in (\"PACKAGE_DISTRIBUTION_MAPPING\", \"PACKAGES_DISTRIBUTION_MAPPING\", \"PACKAGE_TO_DISTRIBUTION\", \"_PACKAGE_DISTRIBUTION_MAPPING\"):
        _mapping = getattr(_iu, _name, None)
        if isinstance(_mapping, dict):
            _mapping.setdefault(\"flash_attn\", \"flash-attn\")
            _mapping.setdefault(\"flash-attn\", \"flash-attn\")
except Exception:
    pass
""".strip()
        + "\n",
        encoding="utf-8",
    )
    current = os.environ.get("PYTHONPATH", "")
    os.environ["PYTHONPATH"] = f"{hotfix_dir}:{current}" if current else str(hotfix_dir)


def stop_comfyui_service(comfyui_dir: Path) -> None:
    run(["comfy", "--workspace", str(comfyui_dir), "stop"], check=False, quiet=True)
    time.sleep(1)


def _proxy_url_from_jupyter_url(jupyter_url: str, target_port: int) -> str | None:
    try:
        parsed = urlparse(jupyter_url)
        host = parsed.netloc
        if not host:
            return None
        replaced = re.sub(r"-\d+\.proxy\.runpod\.net$", f"-{target_port}.proxy.runpod.net", host)
        if replaced == host:
            return None
        return urlunparse((parsed.scheme or "https", replaced, "/", "", "", ""))
    except Exception:
        return None


def resolve_runpod_proxy_url(target_port: int) -> str | None:
    pod_id = os.environ.get("RUNPOD_POD_ID", "").strip()
    if pod_id:
        return f"https://{pod_id}-{target_port}.proxy.runpod.net/"

    for key in ("JUPYTER_URL", "RUNPOD_JUPYTER_URL"):
        raw = os.environ.get(key, "").strip()
        if not raw:
            continue
        resolved = _proxy_url_from_jupyter_url(raw, target_port)
        if resolved:
            return resolved
    return None


def start_comfyui_service(comfyui_dir: Path, network_volume: Path, install_start_ts: int | None = None) -> None:
    now = int(time.time())
    metric_start = install_start_ts if install_start_ts and install_start_ts <= now else now
    health_url = "http://127.0.0.1:8188/system_stats"

    if is_http_reachable(health_url):
        print("ComfyUI is already running; restarting to load newly installed files and custom nodes.")
    else:
        print("Ensuring no stale ComfyUI background service is running before launch.")

    stop_comfyui_service(comfyui_dir)
    stop_setup_page_server()
    _apply_flash_attn_runtime_hotfix()
    sanitize_torch_cuda_alloc_conf()
    _ensure_manager_runtime_ready(comfyui_dir, network_volume)

    print("Starting ComfyUI via comfy-cli")
    run(
        [
            "comfy",
            "--workspace",
            str(comfyui_dir),
            "launch",
            "--background",
            "--",
            "--listen",
            "0.0.0.0",
            "--enable-manager",
            "--disable-cuda-malloc",
        ],
        cwd=comfyui_dir,
    )

    max_wait = 90
    waited = 0
    while waited < max_wait:
        if is_http_reachable(health_url):
            elapsed = int(time.time()) - metric_start
            minutes, seconds = divmod(elapsed, 60)
            if minutes:
                print(f"ComfyUI is UP ({minutes}m {seconds}s)")
            else:
                print(f"ComfyUI is UP ({elapsed}s)")
            runpod_url = resolve_runpod_proxy_url(8188)
            if runpod_url:
                print(f"ComfyUI GUI: {runpod_url}")
            else:
                print("ComfyUI GUI: http://127.0.0.1:8188")
            return
        print("ComfyUI starting...")
        time.sleep(2)
        waited += 2

    stop_comfyui_service(comfyui_dir)
    raise RuntimeError("ComfyUI failed to become ready within 90s")


def prepare_network_volume_and_start_jupyter(network_volume: Path) -> Path:
    notebook_dir = Path("/workspace")
    actual = network_volume
    if not actual.is_dir():
        print(f"NETWORK_VOLUME directory '{network_volume}' does not exist. Using '/' as fallback.")
        actual = Path("/")
        notebook_dir = Path("/")

    if command_exists("jupyter-lab"):
        jupyter_cmd = ["jupyter-lab"]
    elif command_exists("jupyter"):
        jupyter_cmd = ["jupyter", "lab"]
    else:
        raise RuntimeError("JupyterLab is not installed in this image")

    log_path = Path("/tmp/dynamic-comfyui-jupyter.log")
    log_path.unlink(missing_ok=True)
    print(f"Starting JupyterLab on 0.0.0.0:8888 (root: {notebook_dir})")

    with log_path.open("w", encoding="utf-8") as log_file:
        proc = subprocess.Popen(  # noqa: S603
            [
                *jupyter_cmd,
                "--ip=0.0.0.0",
                "--ServerApp.port=8888",
                "--ServerApp.port_retries=0",
                "--ServerApp.token=",
                "--ServerApp.password=",
                "--allow-root",
                "--no-browser",
                "--ServerApp.allow_origin=*",
                "--ServerApp.allow_credentials=True",
                f"--ServerApp.root_dir={notebook_dir}",
            ],
            stdout=log_file,
            stderr=log_file,
        )

    waited = 0
    while waited < 25:
        if proc.poll() is not None:
            tail = log_path.read_text(encoding="utf-8")[-4000:] if log_path.is_file() else ""
            raise RuntimeError(f"JupyterLab process exited during startup.\n{tail}")
        if is_http_reachable("http://127.0.0.1:8888/lab"):
            print("JupyterLab is ready on port 8888.")
            return actual
        time.sleep(1)
        waited += 1

    tail = log_path.read_text(encoding="utf-8")[-4000:] if log_path.is_file() else ""
    raise RuntimeError(f"JupyterLab did not become reachable on port 8888 within 25s.\n{tail}")


def maybe_enable_nodes_setting(network_volume: Path) -> None:
    settings_file = network_volume / "ComfyUI" / "user" / "default" / "comfy.settings.json"
    ensure_dir(settings_file.parent)
    payload = {}
    if settings_file.is_file():
        try:
            import json

            loaded = json.loads(settings_file.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                payload = loaded
        except Exception:
            payload = {}
    payload["Comfy.VueNodes.Enabled"] = True
    import json

    settings_file.write_text(json.dumps(payload, indent=4) + "\n", encoding="utf-8")


def configure_process_env() -> None:
    configure_tcmalloc_preload()
