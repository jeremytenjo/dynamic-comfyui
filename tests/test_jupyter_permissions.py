from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from dynamic_comfyui_runtime.runtime.jupyter_permissions import ensure_jupyter_delete_permissions


class JupyterPermissionsTests(unittest.TestCase):
    def test_ensure_jupyter_delete_permissions_creates_trash_dirs(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            notebook_dir = home / "workspace"
            notebook_dir.mkdir(parents=True, exist_ok=True)

            with patch("dynamic_comfyui_runtime.runtime.jupyter_permissions.Path.home", return_value=home):
                ensure_jupyter_delete_permissions(notebook_dir=notebook_dir)

            trash_root = home / ".local" / "share" / "Trash"
            self.assertTrue((trash_root / "files").is_dir())
            self.assertTrue((trash_root / "info").is_dir())


if __name__ == "__main__":
    unittest.main()
