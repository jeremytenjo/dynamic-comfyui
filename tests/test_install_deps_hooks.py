from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from dynamic_comfyui_runtime.runtime.operations import RuntimeContext, cmd_install_deps


class InstallDepsHooksTests(unittest.TestCase):
    def _ctx(self, network_volume: Path) -> RuntimeContext:
        return RuntimeContext(
            network_volume=network_volume,
            package_json_path=network_volume / "package.json",
            setup_page_html_path=network_volume / "setup_page.html",
            configured_network_volume=network_volume,
        )

    def test_multi_url_duplicate_on_install_complete_hook_raises(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ctx = self._ctx(root)
            manifest_a = root / "a.json"
            manifest_b = root / "b.json"
            manifest_a.write_text(
                '{"custom_nodes":[],"files":[],"hooks":{"on_install_complete":{"commands":["echo a"]}}}\n',
                encoding="utf-8",
            )
            manifest_b.write_text(
                '{"custom_nodes":[],"files":[],"hooks":{"on_install_complete":{"commands":["echo b"]}}}\n',
                encoding="utf-8",
            )

            with (
                patch("dynamic_comfyui_runtime.runtime.operations.configure_process_env"),
                patch("dynamic_comfyui_runtime.runtime.operations.discover_comfyui_workspace", return_value=None),
                patch("dynamic_comfyui_runtime.runtime.operations.resolve_default_manifest", return_value=root / "default.json"),
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.prepare_project_manifest",
                    side_effect=[(manifest_a, "https://example.com/a.json"), (manifest_b, "https://example.com/b.json")],
                ),
            ):
                with self.assertRaises(RuntimeError):
                    cmd_install_deps(ctx, ["https://example.com/a.json", "https://example.com/b.json"])

    def test_multi_url_end_prompt_runs_commands_after_installs(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ctx = self._ctx(root)
            manifest_a = root / "a.json"
            manifest_b = root / "b.json"
            manifest_a.write_text(
                '{"custom_nodes":[],"files":[],"hooks":{"on_install_complete":{"commands":["echo a"]}}}\n',
                encoding="utf-8",
            )
            manifest_b.write_text('{"custom_nodes":[],"files":[]}\n', encoding="utf-8")

            with (
                patch("dynamic_comfyui_runtime.runtime.operations.configure_process_env"),
                patch("dynamic_comfyui_runtime.runtime.operations.discover_comfyui_workspace", return_value=None),
                patch("dynamic_comfyui_runtime.runtime.operations.resolve_default_manifest", return_value=root / "default.json"),
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.prepare_project_manifest",
                    side_effect=[(manifest_a, "https://example.com/a.json"), (manifest_b, "https://example.com/b.json")],
                ),
                patch("dynamic_comfyui_runtime.runtime.operations.ensure_comfyui_workspace", return_value=(root / "ComfyUI", root / "ComfyUI/custom_nodes")),
                patch("dynamic_comfyui_runtime.runtime.operations._load_manifest_context", return_value=(object(), None)),
                patch("dynamic_comfyui_runtime.runtime.operations._ensure_hf_token_for_manifest_batch", return_value=None),
                patch("dynamic_comfyui_runtime.runtime.operations.run_dependency_install_flow") as run_flow,
                patch("dynamic_comfyui_runtime.runtime.operations._save_selected_project"),
                patch("dynamic_comfyui_runtime.runtime.operations.confirm_and_run_on_install_complete_commands") as run_hooks,
            ):
                cmd_install_deps(ctx, ["https://example.com/a.json", "https://example.com/b.json"])

            self.assertEqual(run_flow.call_count, 2)
            run_hooks.assert_called_once()
            args, kwargs = run_hooks.call_args
            self.assertEqual(args[0], ["echo a"])
            self.assertEqual(kwargs["cwd"], root)

    def test_multi_url_end_prompt_skip_still_succeeds(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ctx = self._ctx(root)
            manifest_a = root / "a.json"
            manifest_a.write_text(
                '{"custom_nodes":[],"files":[],"hooks":{"on_install_complete":{"commands":["echo a"]}}}\n',
                encoding="utf-8",
            )

            with (
                patch("dynamic_comfyui_runtime.runtime.operations.configure_process_env"),
                patch("dynamic_comfyui_runtime.runtime.operations.discover_comfyui_workspace", return_value=None),
                patch("dynamic_comfyui_runtime.runtime.operations.resolve_default_manifest", return_value=root / "default.json"),
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.prepare_project_manifest",
                    return_value=(manifest_a, "https://example.com/a.json"),
                ),
                patch("dynamic_comfyui_runtime.runtime.operations.ensure_comfyui_workspace", return_value=(root / "ComfyUI", root / "ComfyUI/custom_nodes")),
                patch("dynamic_comfyui_runtime.runtime.operations._load_manifest_context", return_value=(object(), None)),
                patch("dynamic_comfyui_runtime.runtime.operations._ensure_hf_token_for_manifest_batch", return_value=None),
                patch("dynamic_comfyui_runtime.runtime.operations.run_dependency_install_flow"),
                patch("dynamic_comfyui_runtime.runtime.operations._save_selected_project"),
                patch("dynamic_comfyui_runtime.runtime.operations.confirm_and_run_on_install_complete_commands"),
            ):
                cmd_install_deps(ctx, ["https://example.com/a.json"])


if __name__ == "__main__":
    unittest.main()
