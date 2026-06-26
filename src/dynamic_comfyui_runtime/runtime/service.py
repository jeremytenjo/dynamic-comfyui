from __future__ import annotations

import os
import re
import signal
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
from .jupyter_permissions import ensure_jupyter_delete_permissions
from .progress import stop_setup_page_server
from .ui import print_info, print_warning


def _looks_like_comfyui_workspace(path: Path) -> bool:
    return (
        path.is_dir()
        and (path / ".git").is_dir()
        and (path / "main.py").is_file()
        and (path / "custom_nodes").is_dir()
        and (path / "models").is_dir()
    )


def discover_comfyui_workspace(network_volume: Path) -> Path | None:
    candidates: list[Path] = []

    # Respect configured/default volume first.
    candidates.append(network_volume / "ComfyUI")
    # Common image path.
    candidates.append(Path("/ComfyUI"))

    cwd = Path.cwd()
    candidates.append(cwd / "ComfyUI")
    for parent in cwd.parents:
        candidates.append(parent / "ComfyUI")
        if parent.name == "ComfyUI":
            candidates.append(parent)

    for root in (Path("/workspace"), Path("/runpod-volume"), Path("/data"), Path("/root")):
        if not root.is_dir():
            continue
        candidates.append(root / "ComfyUI")
        try:
            for child in root.iterdir():
                if child.is_dir():
                    candidates.append(child / "ComfyUI")
        except Exception:
            continue

    seen: set[Path] = set()
    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except Exception:
            continue
        if resolved in seen:
            continue
        seen.add(resolved)
        if _looks_like_comfyui_workspace(resolved):
            return resolved
    return None


def _image_comfyui_workspace_path() -> Path:
    return Path("/ComfyUI")


def set_network_volume_default(network_volume: Path) -> Path:
    if network_volume.is_dir():
        return network_volume
    print_info(f"NETWORK_VOLUME directory '{network_volume}' does not exist. Using '/' as fallback.")
    return Path("/")


def ensure_comfyui_workspace(network_volume: Path) -> tuple[Path, Path]:
    comfyui_dir = network_volume / "ComfyUI"
    custom_nodes_dir = comfyui_dir / "custom_nodes"
    ensure_dir(network_volume)

    root_comfy = _image_comfyui_workspace_path()
    root_is_image_workspace = (
        root_comfy != comfyui_dir
        and root_comfy.is_dir()
        and not root_comfy.is_symlink()
        and _looks_like_comfyui_workspace(root_comfy)
    )
    target_is_valid = _looks_like_comfyui_workspace(comfyui_dir)
    if root_is_image_workspace and not target_is_valid:
        if comfyui_dir.exists():
            backup_base = comfyui_dir.with_name(f"{comfyui_dir.name}.invalid-{int(time.time())}")
            backup_dir = backup_base
            suffix = 1
            while backup_dir.exists():
                backup_dir = backup_base.with_name(f"{backup_base.name}-{suffix}")
                suffix += 1
            print_warning(f"Backing up invalid ComfyUI workspace at {comfyui_dir} to {backup_dir}")
            comfyui_dir.rename(backup_dir)
        print_info(f"Moving image ComfyUI workspace to persistent volume: {comfyui_dir}")
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
        print_info("Installing comfy-cli...")
        _install_comfy_cli(network_volume)
    if not command_exists("comfy"):
        raise RuntimeError("comfy-cli installation completed but 'comfy' command is not available")
    # This command is best-effort; do not block runtime setup on telemetry config.
    try:
        run(["comfy", "tracking", "disable"], check=False, quiet=True, timeout=20, input_text="n\n")
    except Exception as exc:
        print_warning(f"comfy tracking disable skipped: {exc}")


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


def enable_manager_gui(comfyui_dir: Path, *, quiet: bool = False) -> None:
    if not quiet:
        print_info("Enabling ComfyUI-Manager modern UI...")
    run(
        ["comfy", "--workspace", str(comfyui_dir), "manager", "enable-gui"],
        timeout=30,
        input_text="n\n",
        quiet=quiet,
    )


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
    if command_exists("comfy"):
        run(["comfy", "--workspace", str(comfyui_dir), "stop"], check=False, quiet=True, timeout=15, input_text="\n")
    if is_main_py_listen_process_running():
        run(["pkill", "-f", "main.py"], check=False, quiet=True)
    run(["pkill", "-f", "ComfyUI"], check=False, quiet=True)
    run(["pkill", "-f", "main.py --listen 0.0.0.0 --port 8188"], check=False, quiet=True)
    time.sleep(1)


def is_main_py_listen_process_running() -> bool:
    if not command_exists("pgrep"):
        return False
    out = run(["pgrep", "-af", "main.py --listen 0.0.0.0"], check=False, quiet=True)
    return bool((out.stdout or "").strip())


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


def _read_log_tail(path: Path, *, max_chars: int = 4000) -> str:
    if not path.is_file():
        return ""
    try:
        return path.read_text(encoding="utf-8", errors="replace")[-max_chars:].strip()
    except Exception:
        return ""


def _wait_for_comfyui_ready(metric_start: int, *, log_path: Path | None = None) -> list[str]:
    health_url = "http://127.0.0.1:8188/system_stats"
    startup_lines: list[str] = []
    max_wait = 90
    waited = 0
    while waited < max_wait:
        if is_http_reachable(health_url):
            elapsed = int(time.time()) - metric_start
            minutes, seconds = divmod(elapsed, 60)
            startup_time = f"{minutes}m {seconds}s" if minutes else f"{elapsed}s"
            runpod_url = resolve_runpod_proxy_url(8188)
            gui_url = runpod_url if runpod_url else "http://127.0.0.1:8188"
            startup_lines.append(f"ComfyUI running: [url]{gui_url}[/] ({startup_time})")
            return startup_lines
        if log_path is not None:
            tail = _read_log_tail(log_path)
            if "runtimeerror:" in tail.lower():
                raise RuntimeError(f"ComfyUI runtime error during startup:\n{tail}")
        print_info("ComfyUI starting...")
        time.sleep(2)
        waited += 2
    details = "ComfyUI failed to become ready within 90s"
    if log_path is not None:
        tail = _read_log_tail(log_path)
        if tail:
            details = f"{details}\nLast startup log lines ({log_path}):\n{tail}"
    raise RuntimeError(details)


def start_comfyui_service(comfyui_dir: Path, network_volume: Path, install_start_ts: int | None = None) -> list[str]:
    now = int(time.time())
    metric_start = install_start_ts if install_start_ts and install_start_ts <= now else now
    health_url = "http://127.0.0.1:8188/system_stats"

    if is_http_reachable(health_url):
        print_info("ComfyUI is already running; restarting to load newly installed files and custom nodes.")
    else:
        print_info("Ensuring no stale ComfyUI background service is running before launch.")

    stop_comfyui_service(comfyui_dir)
    stop_setup_page_server()
    _apply_flash_attn_runtime_hotfix()
    sanitize_torch_cuda_alloc_conf()
    _ensure_manager_runtime_ready(comfyui_dir, network_volume)

    print_info("Starting ComfyUI via comfy-cli")
    launch = run(
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
            "--cache-none",
            "--mmap-torch-files",
        ],
        cwd=comfyui_dir,
        quiet=True,
        timeout=60,
        input_text="\n",
        check=False,
    )
    if launch.returncode != 0:
        stdout_text = launch.stdout or ""
        stderr_text = launch.stderr or ""
        combined = f"{stdout_text}\n{stderr_text}".strip()
        if "runtimeerror:" in combined.lower():
            raise RuntimeError(f"comfy-cli launch failed with runtime error: {combined[-4000:]}")
        exc = RuntimeError(
            f"Command failed ({launch.returncode}): comfy launch"
            + (f" (stderr: {stderr_text[-600:]})" if stderr_text else "")
            + (f" (stdout: {stdout_text[-600:]})" if stdout_text else "")
        )
        main_py = comfyui_dir / "main.py"
        if main_py.is_file():
            print_warning(
                f"comfy-cli launch failed ({exc}). Falling back to `python main.py --listen 0.0.0.0 --port 8188`."
            )
            return start_comfyui_service_via_main_py(comfyui_dir, install_start_ts=install_start_ts)
        raise exc

    try:
        return _wait_for_comfyui_ready(metric_start)
    except Exception:
        stop_comfyui_service(comfyui_dir)
        raise


def start_comfyui_service_via_main_py(comfyui_dir: Path, install_start_ts: int | None = None) -> list[str]:
    now = int(time.time())
    metric_start = install_start_ts if install_start_ts and install_start_ts <= now else now
    health_url = "http://127.0.0.1:8188/system_stats"

    if is_http_reachable(health_url):
        print_info("ComfyUI is already running; restarting to load newly installed files and custom nodes.")
    else:
        print_info("Ensuring no stale ComfyUI background service is running before launch.")

    stop_comfyui_service(comfyui_dir)
    stop_setup_page_server()
    _apply_flash_attn_runtime_hotfix()
    sanitize_torch_cuda_alloc_conf()

    if not comfyui_dir.is_dir():
        raise RuntimeError(f"ComfyUI workspace directory does not exist: {comfyui_dir}")
    if not (comfyui_dir / "main.py").is_file():
        raise RuntimeError(f"ComfyUI main.py not found in workspace: {comfyui_dir / 'main.py'}")

    print_info(f"Starting ComfyUI via main.py (cwd: {comfyui_dir})")
    python_cmd = "python" if command_exists("python") else "python3"
    log_path = Path("/tmp/dynamic-comfyui-main.log")
    log_path.unlink(missing_ok=True)
    with log_path.open("w", encoding="utf-8") as log_file:
        subprocess.Popen(  # noqa: S603
            [
                python_cmd,
                "main.py",
                "--listen",
                "0.0.0.0",
                "--port",
                "8188",
                "--cache-none",
                "--mmap-torch-files",
            ],
            cwd=str(comfyui_dir),
            stdout=log_file,
            stderr=log_file,
        )

    try:
        return _wait_for_comfyui_ready(metric_start, log_path=log_path)
    except Exception:
        stop_comfyui_service(comfyui_dir)
        raise


def start_comfyui_service_foreground(
    comfyui_dir: Path, network_volume: Path, install_start_ts: int | None = None
) -> None:
    _ = install_start_ts
    health_url = "http://127.0.0.1:8188/system_stats"
    if is_http_reachable(health_url):
        print_info("ComfyUI is already running; restarting in foreground.")
    else:
        print_info("Ensuring no stale ComfyUI background service is running before launch.")

    stop_comfyui_service(comfyui_dir)
    stop_setup_page_server()
    _apply_flash_attn_runtime_hotfix()
    sanitize_torch_cuda_alloc_conf()
    _ensure_manager_runtime_ready(comfyui_dir, network_volume)

    main_py = comfyui_dir / "main.py"
    if not comfyui_dir.is_dir():
        raise RuntimeError(f"ComfyUI workspace directory does not exist: {comfyui_dir}")
    if not main_py.is_file():
        raise RuntimeError(f"ComfyUI main.py not found in workspace: {main_py}")

    runpod_url = resolve_runpod_proxy_url(8188)
    gui_url = runpod_url if runpod_url else "http://127.0.0.1:8188"
    print_info(f"Starting ComfyUI in foreground via main.py (cwd: {comfyui_dir})")
    print_info(f"ComfyUI URL: [url]{gui_url}[/]")
    print_info("Press Ctrl+C to stop ComfyUI.")

    python_cmd = "python" if command_exists("python") else "python3"
    proc = subprocess.Popen(  # noqa: S603
        [
            python_cmd,
            "main.py",
            "--listen",
            "0.0.0.0",
            "--port",
            "8188",
            "--enable-manager",
            "--disable-cuda-malloc",
            "--cache-none",
            "--mmap-torch-files",
        ],
        cwd=str(comfyui_dir),
    )
    try:
        returncode = proc.wait()
    except KeyboardInterrupt:
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
            proc.wait()
        raise
    if returncode != 0:
        raise RuntimeError(f"ComfyUI foreground process exited with code {returncode}")


def prepare_network_volume_and_start_jupyter(network_volume: Path) -> Path:
    notebook_dir = Path("/workspace")
    actual = network_volume
    if not actual.is_dir():
        print_info(f"NETWORK_VOLUME directory '{network_volume}' does not exist. Using '/' as fallback.")
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
    ensure_jupyter_delete_permissions(notebook_dir=notebook_dir)
    print_info(f"Starting JupyterLab on 0.0.0.0:8888 (root: {notebook_dir})")

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
            print_info("JupyterLab is ready on port 8888.")
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
