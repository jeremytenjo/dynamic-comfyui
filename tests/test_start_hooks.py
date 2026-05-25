from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from dynamic_comfyui_runtime.runtime.operations import RuntimeContext, cmd_start


class StartHooksTests(unittest.TestCase):
    def _ctx(self, network_volume: Path) -> RuntimeContext:
        return RuntimeContext(
            network_volume=network_volume,
            package_json_path=network_volume / "package.json",
            setup_page_html_path=network_volume / "setup_page.html",
            configured_network_volume=network_volume,
        )

    def test_start_reuses_saved_project_with_on_install_complete_and_skips_prompt(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ctx = self._ctx(root)
            saved_manifest = root / "saved.json"
            saved_manifest.write_text(
                '{"custom_nodes":[],"files":[],"hooks":{"on_install_complete":{"commands":["echo saved"]}}}\n',
                encoding="utf-8",
            )

            with (
                patch("dynamic_comfyui_runtime.runtime.operations.configure_process_env"),
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.load_project_state",
                    return_value=("active-project", "https://example.com/saved.json"),
                ),
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.prepare_project_manifest",
                    return_value=(saved_manifest, "https://example.com/saved.json"),
                ),
                patch("dynamic_comfyui_runtime.runtime.operations.prompt_and_prepare_project_manifest") as prompt_manifest,
                patch("dynamic_comfyui_runtime.runtime.operations._save_selected_project"),
                patch("dynamic_comfyui_runtime.runtime.operations.run_comfyui_install_flow"),
                patch("dynamic_comfyui_runtime.runtime.operations.run_on_install_complete_commands") as run_hook_commands,
            ):
                cmd_start(ctx)

            prompt_manifest.assert_not_called()
            run_hook_commands.assert_called_once_with(["echo saved"], cwd=root)

    def test_start_runs_on_install_complete_when_project_url_is_provided(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ctx = self._ctx(root)
            provided_manifest = root / "provided.json"
            provided_manifest.write_text(
                '{"custom_nodes":[],"files":[],"hooks":{"on_install_complete":{"commands":["echo provided"]}}}\n',
                encoding="utf-8",
            )

            with (
                patch("dynamic_comfyui_runtime.runtime.operations.configure_process_env"),
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.prepare_project_manifest",
                    return_value=(provided_manifest, "https://example.com/provided.json"),
                ),
                patch("dynamic_comfyui_runtime.runtime.operations._save_selected_project"),
                patch("dynamic_comfyui_runtime.runtime.operations.run_comfyui_install_flow"),
                patch("dynamic_comfyui_runtime.runtime.operations.run_on_install_complete_commands") as run_hook_commands,
            ):
                cmd_start(ctx, "https://example.com/provided.json")

            run_hook_commands.assert_called_once_with(["echo provided"], cwd=root)


if __name__ == "__main__":
    unittest.main()
