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

    def test_start_reuses_saved_project_with_on_install_complete_and_prompts_at_end(self) -> None:
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
                patch("dynamic_comfyui_runtime.runtime.operations.run_dependency_install_flow") as run_dependency_install,
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.start_comfyui_service_foreground"
                ) as run_comfyui_foreground,
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.ensure_comfyui_workspace",
                    return_value=(root / "ComfyUI", root / "ComfyUI" / "custom_nodes"),
                ),
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.confirm_and_run_on_install_complete_commands"
                ) as confirm_and_run_hooks,
            ):
                cmd_start(ctx)

            prompt_manifest.assert_not_called()
            run_dependency_install.assert_called_once_with(ctx, saved_manifest)
            confirm_and_run_hooks.assert_called_once_with(["echo saved"], cwd=root)
            run_comfyui_foreground.assert_called_once()

    def test_start_runs_on_install_complete_confirmation_when_project_url_is_provided(self) -> None:
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
                patch("dynamic_comfyui_runtime.runtime.operations.run_dependency_install_flow") as run_dependency_install,
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.start_comfyui_service_foreground"
                ) as run_comfyui_foreground,
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.ensure_comfyui_workspace",
                    return_value=(root / "ComfyUI", root / "ComfyUI" / "custom_nodes"),
                ),
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.confirm_and_run_on_install_complete_commands"
                ) as confirm_and_run_hooks,
            ):
                cmd_start(ctx, "https://example.com/provided.json")

            run_dependency_install.assert_called_once_with(ctx, provided_manifest)
            confirm_and_run_hooks.assert_called_once_with(["echo provided"], cwd=root)
            run_comfyui_foreground.assert_called_once()

    def test_start_uses_foreground_comfyui_install_flow_when_manifest_has_no_hook_commands(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ctx = self._ctx(root)
            manifest = root / "project.json"
            manifest.write_text('{"custom_nodes":[],"files":[]}\n', encoding="utf-8")

            with (
                patch("dynamic_comfyui_runtime.runtime.operations.configure_process_env"),
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.prepare_project_manifest",
                    return_value=(manifest, "https://example.com/project.json"),
                ),
                patch("dynamic_comfyui_runtime.runtime.operations._save_selected_project"),
                patch("dynamic_comfyui_runtime.runtime.operations.run_dependency_install_flow") as run_dependency_install,
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.run_comfyui_install_flow_foreground"
                ) as run_comfyui_install,
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.confirm_and_run_on_install_complete_commands"
                ) as confirm_and_run_hooks,
            ):
                cmd_start(ctx, "https://example.com/project.json")

            run_comfyui_install.assert_called_once_with(ctx, manifest)
            run_dependency_install.assert_not_called()
            confirm_and_run_hooks.assert_not_called()


if __name__ == "__main__":
    unittest.main()
