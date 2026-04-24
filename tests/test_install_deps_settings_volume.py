from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from dynamic_comfyui_runtime.runtime.operations import RuntimeContext, cmd_install_deps


class InstallDepsSettingsVolumeTests(unittest.TestCase):
    def test_install_deps_uses_configured_settings_volume_when_workspace_differs(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            configured_root = Path(td) / "configured"
            detected_root = Path(td) / "detected"
            configured_root.mkdir(parents=True, exist_ok=True)
            detected_root.mkdir(parents=True, exist_ok=True)
            detected_workspace = detected_root / "ComfyUI"
            detected_workspace.mkdir(parents=True, exist_ok=True)

            ctx = RuntimeContext(
                network_volume=configured_root,
                package_json_path=configured_root / "package.json",
                setup_page_html_path=configured_root / "setup.html",
                configured_network_volume=configured_root,
            )

            with (
                patch("dynamic_comfyui_runtime.runtime.operations.configure_process_env"),
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.discover_comfyui_workspace",
                    return_value=detected_workspace,
                ),
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.resolve_default_manifest",
                    return_value=detected_root / "defaults.json",
                ) as resolve_default_manifest_mock,
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.prepare_project_manifest",
                    return_value=(detected_root / "project.json", "https://example.com/project.json"),
                ),
                patch("dynamic_comfyui_runtime.runtime.operations._save_selected_project"),
                patch("dynamic_comfyui_runtime.runtime.operations.run_dependency_install_flow"),
            ):
                cmd_install_deps(ctx, ["https://example.com/project.json"])

            resolve_default_manifest_mock.assert_called_once()
            args, kwargs = resolve_default_manifest_mock.call_args
            # package_json_path, temp_dir, settings_network_volume
            self.assertEqual(args[2], configured_root)
            self.assertEqual(kwargs["fallback_network_volume"], detected_root)


if __name__ == "__main__":
    unittest.main()
