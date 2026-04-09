from __future__ import annotations

import json
import subprocess
from pathlib import Path

from .common import ensure_dir, now_epoch
from .manifests import CustomNode, FileSpec, MergedManifest

SETUP_DIR = Path("/tmp/dynamic-comfyui-setup-page")
PROGRESS_FILE = SETUP_DIR / "progress.json"
SETUP_PID_FILE = Path("/tmp/dynamic-comfyui-setup-page.pid")


def _item_checked(comfyui_dir: Path, target: str, kind: str) -> bool:
    path = comfyui_dir / target
    if kind == "custom_node":
        return path.is_dir()
    return path.is_file()


def _nodes_to_items(nodes: list[CustomNode], source: str) -> list[dict]:
    return [
        {
            "target": f"custom_nodes/{node.repo_dir}",
            "url": node.repo,
            "kind": "custom_node",
            "source": source,
        }
        for node in nodes
    ]


def _files_to_items(files: list[FileSpec], source: str) -> list[dict]:
    return [
        {
            "target": file_spec.target,
            "url": file_spec.url,
            "kind": "file",
            "source": source,
        }
        for file_spec in files
    ]


def write_progress(status: str, message: str, merged: MergedManifest | None, comfyui_dir: Path) -> None:
    ensure_dir(SETUP_DIR)

    default_items: list[dict] = []
    project_items: list[dict] = []
    if merged is not None:
        default_items = _nodes_to_items(merged.default_custom_nodes, "default") + _files_to_items(merged.default_files, "default")
        project_items = _nodes_to_items(merged.project_custom_nodes, "project") + _files_to_items(merged.project_files, "project")

    for item in default_items + project_items:
        item["checked"] = _item_checked(comfyui_dir, item["target"], item["kind"])

    payload = {
        "status": status,
        "message": message,
        "updated_at": now_epoch(),
        "groups": {
            "default": {"label": "Default resources", "items": default_items},
            "project": {"label": "Project manifest", "items": project_items},
        },
    }
    PROGRESS_FILE.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def mark_idle(merged: MergedManifest | None, comfyui_dir: Path) -> None:
    write_progress("idle", "Waiting for installation to start.", merged, comfyui_dir)


def mark_running(merged: MergedManifest | None, comfyui_dir: Path, message: str = "Downloading resources...") -> None:
    write_progress("running", message, merged, comfyui_dir)


def mark_done(merged: MergedManifest | None, comfyui_dir: Path) -> None:
    write_progress("done", "Installation complete.", merged, comfyui_dir)


def mark_failed(merged: MergedManifest | None, comfyui_dir: Path, message: str) -> None:
    write_progress("failed", message, merged, comfyui_dir)


def stop_setup_page_server() -> None:
    if SETUP_PID_FILE.is_file():
        try:
            pid = int(SETUP_PID_FILE.read_text(encoding="utf-8").strip())
            Path(f"/proc/{pid}")
            try:
                subprocess.run(["kill", str(pid)], check=False)  # noqa: S603,S607
            except Exception:
                pass
        except Exception:
            pass
        SETUP_PID_FILE.unlink(missing_ok=True)


def start_setup_page_server(html_path: Path) -> None:
    stop_setup_page_server()
    ensure_dir(SETUP_DIR)
    html_target = SETUP_DIR / "index.html"
    html_target.write_text(html_path.read_text(encoding="utf-8"), encoding="utf-8")

    proc = subprocess.Popen(  # noqa: S603
        ["python3", "-m", "http.server", "8188", "--directory", str(SETUP_DIR)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    SETUP_PID_FILE.write_text(f"{proc.pid}\n", encoding="utf-8")
