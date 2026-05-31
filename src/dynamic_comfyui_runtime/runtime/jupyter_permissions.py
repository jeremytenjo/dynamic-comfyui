from __future__ import annotations

import os
from pathlib import Path

from .ui import print_info, print_warning


def _ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    try:
        path.chmod(0o700)
    except Exception:
        # Best effort only; ownership may prevent chmod in some pods.
        pass


def _is_writable_directory(path: Path) -> bool:
    try:
        return path.is_dir() and os.access(path, os.W_OK | os.X_OK)
    except Exception:
        return False


def ensure_jupyter_delete_permissions(*, notebook_dir: Path) -> None:
    home = Path.home()
    trash_root = home / ".local" / "share" / "Trash"
    trash_files = trash_root / "files"
    trash_info = trash_root / "info"

    _ensure_dir(trash_files)
    _ensure_dir(trash_info)

    if _is_writable_directory(trash_files) and _is_writable_directory(trash_info):
        print_info(f"Jupyter delete support ready (Trash: {trash_root}).")
    else:
        print_warning(
            f"Trash directory is not writable ({trash_root}). Jupyter file delete may fail with permission denied."
        )

    if not _is_writable_directory(notebook_dir):
        print_warning(
            f"Notebook root is not writable ({notebook_dir}). File operations may fail until ownership/permissions are fixed."
        )
