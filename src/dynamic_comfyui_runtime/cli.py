from __future__ import annotations

import argparse
import os
from pathlib import Path

from .runtime.operations import (
    RuntimeContext,
    cmd_add_project,
    cmd_install,
    cmd_replace_project,
    cmd_restart,
    cmd_start,
    cmd_start_new_project,
    cmd_update_dc,
    cmd_update_nodes_and_models,
)
from .runtime.updater import REEXEC_FLAG, upgrade_runtime_package_and_reexec_install


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _default_package_json_path() -> Path:
    for candidate in (Path("/package.json"), _repo_root() / "package.json"):
        if candidate.is_file():
            return candidate
    return Path("/package.json")


def _default_setup_page_html_path() -> Path:
    candidate = Path(__file__).resolve().parent / "templates" / "setup_page.html"
    if candidate.is_file():
        return candidate
    raise RuntimeError("Setup page HTML template not found")


def _context() -> RuntimeContext:
    network_volume = Path(os.environ.get("NETWORK_VOLUME", "/workspace"))
    return RuntimeContext(
        network_volume=network_volume,
        package_json_path=_default_package_json_path(),
        setup_page_html_path=_default_setup_page_html_path(),
    )


def _help_text() -> str:
    return """Dynamic ComfyUI Commands

- ComfyUI core version
  Managed at image build time via GitHub Action inputs (upgrade_comfyui/comfyui_version), not project JSON.

- dynamic-comfyui install
  Boot runtime services for the pod (Jupyter + setup page + optional auto-start).

- dynamic-comfyui start
  Enter a direct JSON URL (or press Enter for defaults-only) and install/start ComfyUI.

- dynamic-comfyui start-new-project
  Enter a new JSON URL (or press Enter for defaults-only) and optionally clean previous project resources.

- dynamic-comfyui add-project
  Enter a new JSON URL (or press Enter for defaults-only) and add missing nodes/files (keeps existing resources).

- dynamic-comfyui replace-project
  Enter a new JSON URL (or press Enter for defaults-only), remove previous project resources, then install/start new resources.

- dynamic-comfyui update-nodes-and-models
  Re-download the last saved JSON URL (or refresh defaults-only if URL is empty), refresh nodes/files, and restart ComfyUI.
  If the manifest sets require_huggingface_token=true, this command prompts for a token each run.
  Create a token at: https://huggingface.co/settings/tokens

- dynamic-comfyui restart
  Restart ComfyUI service.

- dynamic-comfyui update-dc
  Update dynamic-comfyui runtime package to latest release wheel.

- dynamic-comfyui help
  Show this help menu.
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dynamic-comfyui")
    subparsers = parser.add_subparsers(dest="command", required=True)

    for cmd in (
        "install",
        "start",
        "start-new-project",
        "add-project",
        "replace-project",
        "update-nodes-and-models",
        "restart",
        "update-dc",
        "help",
    ):
        subparsers.add_parser(cmd)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "help":
        print(_help_text())
        raise SystemExit(0)

    if args.command == "install":
        if os.environ.get(REEXEC_FLAG) != "1":
            code = upgrade_runtime_package_and_reexec_install()
            raise SystemExit(code)
        cmd_install(_context())
        raise SystemExit(0)

    ctx = _context()
    handlers = {
        "start": cmd_start,
        "start-new-project": cmd_start_new_project,
        "add-project": cmd_add_project,
        "replace-project": cmd_replace_project,
        "update-nodes-and-models": cmd_update_nodes_and_models,
        "restart": cmd_restart,
        "update-dc": cmd_update_dc,
    }

    try:
        handlers[args.command](ctx)
    except Exception as exc:
        print(f"Error: {exc}")
        raise SystemExit(1) from exc


if __name__ == "__main__":
    main()
