from __future__ import annotations

import tempfile
import unittest
from subprocess import CompletedProcess
from pathlib import Path
from unittest.mock import patch

from dynamic_comfyui_runtime.runtime.service import start_comfyui_service
from dynamic_comfyui_runtime.runtime.service import stop_comfyui_service
from dynamic_comfyui_runtime.runtime.service import ensure_comfyui_workspace


class ServiceStartTimeoutTests(unittest.TestCase):
    def test_ensure_comfyui_workspace_replaces_invalid_target_from_image_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            network_volume = root / "workspace"
            invalid_target = network_volume / "ComfyUI"
            invalid_target.mkdir(parents=True, exist_ok=True)
            (invalid_target / "partial.txt").write_text("not a core workspace\n", encoding="utf-8")

            image_workspace = root / "image" / "ComfyUI"
            (image_workspace / ".git").mkdir(parents=True, exist_ok=True)
            (image_workspace / "custom_nodes").mkdir(parents=True, exist_ok=True)
            (image_workspace / "models").mkdir(parents=True, exist_ok=True)
            (image_workspace / "main.py").write_text("print('ok')\n", encoding="utf-8")

            with patch(
                "dynamic_comfyui_runtime.runtime.service._image_comfyui_workspace_path",
                return_value=image_workspace,
            ):
                comfyui_dir, custom_nodes_dir = ensure_comfyui_workspace(network_volume)

            self.assertEqual(comfyui_dir, network_volume / "ComfyUI")
            self.assertEqual(custom_nodes_dir, comfyui_dir / "custom_nodes")
            self.assertTrue((comfyui_dir / "main.py").is_file())
            backups = list(network_volume.glob("ComfyUI.invalid-*"))
            self.assertEqual(len(backups), 1)
            self.assertTrue((backups[0] / "partial.txt").is_file())

    def test_stop_comfyui_service_uses_timeout_for_comfy_stop(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            comfyui_dir = Path(td) / "ComfyUI"
            comfyui_dir.mkdir(parents=True, exist_ok=True)

            with (
                patch("dynamic_comfyui_runtime.runtime.service.command_exists", return_value=True),
                patch("dynamic_comfyui_runtime.runtime.service.is_main_py_listen_process_running", return_value=False),
                patch("dynamic_comfyui_runtime.runtime.service.run") as run_cmd,
            ):
                stop_comfyui_service(comfyui_dir)

            comfy_stop_call = run_cmd.call_args_list[0]
            self.assertEqual(comfy_stop_call.args[0], ["comfy", "--workspace", str(comfyui_dir), "stop"])
            self.assertEqual(comfy_stop_call.kwargs.get("timeout"), 15)
            self.assertEqual(comfy_stop_call.kwargs.get("input_text"), "\n")
            self.assertEqual(comfy_stop_call.kwargs.get("check"), False)
            self.assertEqual(comfy_stop_call.kwargs.get("quiet"), True)

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
                patch(
                    "dynamic_comfyui_runtime.runtime.service.run",
                    return_value=CompletedProcess(args=["comfy", "launch"], returncode=0, stdout="", stderr=""),
                ) as run_cmd,
            ):
                start_comfyui_service(comfyui_dir, root)

            run_cmd.assert_called_once()
            kwargs = run_cmd.call_args.kwargs
            self.assertEqual(kwargs.get("timeout"), 60)
            self.assertEqual(kwargs.get("input_text"), "\n")
            self.assertEqual(kwargs.get("check"), False)

    def test_start_comfyui_service_does_not_fallback_on_runtime_error(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            comfyui_dir = root / "ComfyUI"
            comfyui_dir.mkdir(parents=True, exist_ok=True)
            (comfyui_dir / "main.py").write_text("print('ok')\n", encoding="utf-8")
            launch_error = RuntimeError(
                "Command failed (1): comfy ... stderr: RuntimeError: operator torchvision::nms does not exist"
            )

            with (
                patch("dynamic_comfyui_runtime.runtime.service.is_http_reachable", return_value=False),
                patch("dynamic_comfyui_runtime.runtime.service.stop_comfyui_service"),
                patch("dynamic_comfyui_runtime.runtime.service.stop_setup_page_server"),
                patch("dynamic_comfyui_runtime.runtime.service._apply_flash_attn_runtime_hotfix"),
                patch("dynamic_comfyui_runtime.runtime.service.sanitize_torch_cuda_alloc_conf"),
                patch("dynamic_comfyui_runtime.runtime.service._ensure_manager_runtime_ready"),
                patch("dynamic_comfyui_runtime.runtime.service.run", side_effect=launch_error),
                patch("dynamic_comfyui_runtime.runtime.service.start_comfyui_service_via_main_py") as fallback_start,
            ):
                with self.assertRaises(RuntimeError):
                    start_comfyui_service(comfyui_dir, root)

            fallback_start.assert_not_called()

    def test_start_comfyui_service_does_not_fallback_when_runtime_error_is_in_launch_output(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            comfyui_dir = root / "ComfyUI"
            comfyui_dir.mkdir(parents=True, exist_ok=True)
            (comfyui_dir / "main.py").write_text("print('ok')\n", encoding="utf-8")
            failed_launch = CompletedProcess(
                args=["comfy", "launch"],
                returncode=1,
                stdout="",
                stderr="warning...\nRuntimeError: operator torchvision::nms does not exist\n",
            )

            with (
                patch("dynamic_comfyui_runtime.runtime.service.is_http_reachable", return_value=False),
                patch("dynamic_comfyui_runtime.runtime.service.stop_comfyui_service"),
                patch("dynamic_comfyui_runtime.runtime.service.stop_setup_page_server"),
                patch("dynamic_comfyui_runtime.runtime.service._apply_flash_attn_runtime_hotfix"),
                patch("dynamic_comfyui_runtime.runtime.service.sanitize_torch_cuda_alloc_conf"),
                patch("dynamic_comfyui_runtime.runtime.service._ensure_manager_runtime_ready"),
                patch("dynamic_comfyui_runtime.runtime.service.run", return_value=failed_launch),
                patch("dynamic_comfyui_runtime.runtime.service.start_comfyui_service_via_main_py") as fallback_start,
            ):
                with self.assertRaises(RuntimeError):
                    start_comfyui_service(comfyui_dir, root)

            fallback_start.assert_not_called()


if __name__ == "__main__":
    unittest.main()
