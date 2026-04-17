from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from importlib import metadata
from pathlib import Path

from .common import format_size_for_display


@dataclass
class SystemInfo:
    comfyui_version: str = "N/A"
    frontend_version: str = "N/A"
    python_version: str = "N/A"
    pytorch_version: str = "N/A"
    cuda_core_version: str = "N/A"
    nvidia_driver_version: str = "N/A"
    gpu_model: str = "N/A"
    video_vram: str = "N/A"
    system_ram: str = "N/A"
    pod_volume: str | None = None
    network_volume: str | None = None


def _run_capture(cmd: list[str], *, cwd: Path | None = None) -> str | None:
    try:
        completed = subprocess.run(  # noqa: S603
            cmd,
            cwd=str(cwd) if cwd else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    except Exception:
        return None
    if completed.returncode != 0:
        return None
    out = (completed.stdout or "").strip()
    return out or None


def _read_json_version(path: Path) -> str | None:
    if not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    version = payload.get("version") if isinstance(payload, dict) else None
    if isinstance(version, str) and version.strip():
        return version.strip()
    return None


def _format_bytes_for_display(byte_count: int) -> str:
    if byte_count <= 0:
        return "N/A"
    return format_size_for_display(byte_count)


def _detect_comfyui_version(comfyui_dir: Path | None) -> str:
    if comfyui_dir and comfyui_dir.is_dir():
        tag = _run_capture(["git", "describe", "--tags", "--exact-match"], cwd=comfyui_dir)
        if tag:
            return tag
        described = _run_capture(["git", "describe", "--tags", "--abbrev=0"], cwd=comfyui_dir)
        if described:
            return described
        package_version = _read_json_version(comfyui_dir / "package.json")
        if package_version:
            return package_version
    try:
        return metadata.version("comfyui")
    except Exception:
        return "N/A"


def _detect_frontend_version(comfyui_dir: Path | None) -> str:
    candidates: list[Path] = []
    if comfyui_dir and comfyui_dir.is_dir():
        candidates.extend(
            [
                comfyui_dir / "web" / "package.json",
                comfyui_dir / "web" / "dist" / "package.json",
                comfyui_dir / "frontend" / "package.json",
                comfyui_dir / "package.json",
            ]
        )
    for candidate in candidates:
        version = _read_json_version(candidate)
        if version:
            return version

    for pkg in ("comfyui-frontend-package", "comfyui_frontend_package"):
        try:
            return metadata.version(pkg)
        except Exception:
            continue
    return "N/A"


def _detect_python_version() -> str:
    version = _run_capture(["python3", "-c", "import platform; print(platform.python_version())"])
    return version or "N/A"


def _detect_torch_and_cuda() -> tuple[str, str]:
    code = (
        "import json\n"
        "try:\n"
        "    import torch\n"
        "    payload = {'torch': str(getattr(torch, '__version__', 'N/A')), 'cuda': str(getattr(getattr(torch, 'version', None), 'cuda', None) or 'N/A')}\n"
        "except Exception:\n"
        "    payload = {'torch': 'N/A', 'cuda': 'N/A'}\n"
        "print(json.dumps(payload))\n"
    )
    raw = _run_capture(["python3", "-c", code])
    if not raw:
        return "N/A", "N/A"
    try:
        payload = json.loads(raw)
    except Exception:
        return "N/A", "N/A"
    torch_version = str(payload.get("torch") or "N/A")
    cuda_version = str(payload.get("cuda") or "N/A")
    return torch_version, cuda_version


def _detect_gpu_details() -> tuple[str, str, str]:
    line = _run_capture(
        [
            "nvidia-smi",
            "--query-gpu=driver_version,name,memory.total",
            "--format=csv,noheader,nounits",
        ]
    )
    if not line:
        return "N/A", "N/A", "N/A"
    first = line.splitlines()[0].strip()
    parts = [part.strip() for part in first.split(",")]
    if len(parts) < 3:
        return "N/A", "N/A", "N/A"
    driver_version, gpu_model, memory_mib = parts[0], parts[1], parts[2]
    try:
        memory_bytes = int(float(memory_mib) * 1024 * 1024)
    except Exception:
        return driver_version or "N/A", gpu_model or "N/A", "N/A"
    return driver_version or "N/A", gpu_model or "N/A", _format_bytes_for_display(memory_bytes)


def _detect_system_ram() -> str:
    try:
        page_size = os.sysconf("SC_PAGE_SIZE")
        page_count = os.sysconf("SC_PHYS_PAGES")
        if isinstance(page_size, int) and isinstance(page_count, int) and page_size > 0 and page_count > 0:
            return _format_bytes_for_display(page_size * page_count)
    except Exception:
        pass

    meminfo = Path("/proc/meminfo")
    if not meminfo.is_file():
        return "N/A"
    try:
        for line in meminfo.read_text(encoding="utf-8").splitlines():
            if not line.startswith("MemTotal:"):
                continue
            parts = line.split()
            if len(parts) >= 2:
                kib = int(parts[1])
                return _format_bytes_for_display(kib * 1024)
    except Exception:
        return "N/A"
    return "N/A"


def _format_disk_usage(path: Path) -> str | None:
    if not path.exists():
        return None

    try:
        usage = shutil.disk_usage(path)
    except Exception:
        return None

    total = usage.total
    used = usage.used
    if total <= 0:
        return None
    pct = int((used * 100) / total)
    return f"{format_size_for_display(used)} / {format_size_for_display(total)} ({pct}%)"


def _detect_pod_volume() -> str | None:
    # Pod container/root filesystem usage.
    return _format_disk_usage(Path("/"))


def _detect_network_volume(comfyui_dir: Path | None) -> str | None:
    if comfyui_dir and comfyui_dir.is_dir():
        # ComfyUI workspace is typically "<network_volume>/ComfyUI".
        return _format_disk_usage(comfyui_dir.parent)

    env_volume = os.environ.get("NETWORK_VOLUME", "").strip()
    if not env_volume:
        return None
    return _format_disk_usage(Path(env_volume))


def collect_system_info(comfyui_dir: Path | None = None) -> SystemInfo:
    pytorch_version, cuda_core_version = _detect_torch_and_cuda()
    nvidia_driver_version, gpu_model, video_vram = _detect_gpu_details()
    return SystemInfo(
        comfyui_version=_detect_comfyui_version(comfyui_dir),
        frontend_version=_detect_frontend_version(comfyui_dir),
        python_version=_detect_python_version(),
        pytorch_version=pytorch_version,
        cuda_core_version=cuda_core_version,
        nvidia_driver_version=nvidia_driver_version,
        gpu_model=gpu_model,
        video_vram=video_vram,
        system_ram=_detect_system_ram(),
        pod_volume=_detect_pod_volume(),
        network_volume=_detect_network_volume(comfyui_dir),
    )


def print_system_info(info: SystemInfo) -> None:
    rows = [
        ("ComfyUI", info.comfyui_version),
        ("Frontend", info.frontend_version),
        ("Python", info.python_version),
        ("PyTorch", info.pytorch_version),
        ("CUDA Core", info.cuda_core_version),
        ("NVIDIA drv", info.nvidia_driver_version),
        ("GPU Model", info.gpu_model),
        ("Video VRAM", info.video_vram),
        ("System RAM", info.system_ram),
    ]
    if info.pod_volume:
        rows.append(("Pod Volume", info.pod_volume))
    if info.network_volume:
        rows.append(("Network Volume", info.network_volume))

    label_width = max(len(label) for label, _ in rows)
    print("System info")
    for label, value in rows:
        print(f"{label:<{label_width}}  {value}")
