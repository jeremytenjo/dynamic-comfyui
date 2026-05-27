from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from dynamic_comfyui_runtime.runtime.service import start_comfyui_service


class ServiceStartTimeoutTests(unittest.TestCase):
    def test_start_comfyui_service_uses_timeout_for_comfy_launch(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            comfyui_dir = root / "ComfyUI"
            comfyui_dir.mkdir(parents=True, exist_ok=True)

            with (
                patch("dynamic_comfyui_runtime.runtime.service.is_http_reachable", return_value=False),
                patch("dynamic_comfyui_runtime.runtime.service.stop_comfyui_service"),
                patch("dynamic_comfyui_runtime.runtime.service.stop_setup_page_server"),
                patch("dynamic_comfyui_runtime.runtime.service._apply_flash_attn_runtime_hotfix"),
                patch("dynamic_comfyui_runtime.runtime.service.sanitize_torch_cuda_alloc_conf"),
                patch("dynamic_comfyui_runtime.runtime.service._ensure_manager_runtime_ready"),
                patch("dynamic_comfyui_runtime.runtime.service._wait_for_comfyui_ready", return_value=["ok"]),
                patch("dynamic_comfyui_runtime.runtime.service.run") as run_cmd,
            ):
                start_comfyui_service(comfyui_dir, root)

            run_cmd.assert_called_once()
            kwargs = run_cmd.call_args.kwargs
            self.assertEqual(kwargs.get("timeout"), 60)
            self.assertEqual(kwargs.get("input_text"), "\n")


if __name__ == "__main__":
    unittest.main()
