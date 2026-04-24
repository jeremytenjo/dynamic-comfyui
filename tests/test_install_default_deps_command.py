from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from dynamic_comfyui_runtime.runtime.default_manifest_url import write_default_manifest_url_override
from dynamic_comfyui_runtime.runtime.operations import RuntimeContext, cmd_install_default_deps


class InstallDefaultDepsCommandTests(unittest.TestCase):
    def _ctx(self, network_volume: Path) -> RuntimeContext:
        return RuntimeContext(
            network_volume=network_volume,
            package_json_path=network_volume / "package.json",
            setup_page_html_path=network_volume / "setup_page.html",
        )

    def test_uses_configured_default_without_prompt(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            write_default_manifest_url_override(root, "https://example.com/defaults.json")
            ctx = self._ctx(root)

            with (
                patch("dynamic_comfyui_runtime.runtime.operations.configure_process_env"),
                patch("dynamic_comfyui_runtime.runtime.operations.discover_comfyui_workspace", return_value=None),
                patch("dynamic_comfyui_runtime.runtime.operations.resolve_default_manifest_strict", return_value=root / "d.json"),
                patch("dynamic_comfyui_runtime.runtime.operations.run_dependency_install_flow"),
                patch("dynamic_comfyui_runtime.runtime.operations.prompt_text") as prompt_text,
            ):
                cmd_install_default_deps(ctx)
                prompt_text.assert_not_called()

    def test_prompts_saves_and_runs_when_default_missing(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ctx = self._ctx(root)

            with (
                patch("dynamic_comfyui_runtime.runtime.operations.configure_process_env"),
                patch("dynamic_comfyui_runtime.runtime.operations.discover_comfyui_workspace", return_value=None),
                patch("dynamic_comfyui_runtime.runtime.operations.resolve_default_manifest_strict", return_value=root / "d.json"),
                patch("dynamic_comfyui_runtime.runtime.operations.run_dependency_install_flow"),
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.prompt_text",
                    return_value="https://example.com/defaults.json",
                ) as prompt_text,
            ):
                cmd_install_default_deps(ctx)
                prompt_text.assert_called_once()

            self.assertEqual(
                (root / ".dynamic-comfyui_default_manifest_url").read_text(encoding="utf-8").strip(),
                "https://example.com/defaults.json",
            )

    def test_invalid_prompted_url_raises(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ctx = self._ctx(root)

            with (
                patch("dynamic_comfyui_runtime.runtime.operations.configure_process_env"),
                patch("dynamic_comfyui_runtime.runtime.operations.discover_comfyui_workspace", return_value=None),
                patch("dynamic_comfyui_runtime.runtime.operations.prompt_text", return_value="not-a-url"),
            ):
                with self.assertRaises(ValueError):
                    cmd_install_default_deps(ctx)

    def test_strict_download_failure_surfaces_error(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            write_default_manifest_url_override(root, "https://example.com/defaults.json")
            ctx = self._ctx(root)

            with (
                patch("dynamic_comfyui_runtime.runtime.operations.configure_process_env"),
                patch("dynamic_comfyui_runtime.runtime.operations.discover_comfyui_workspace", return_value=None),
                patch(
                    "dynamic_comfyui_runtime.runtime.operations.resolve_default_manifest_strict",
                    side_effect=RuntimeError("download failed"),
                ),
            ):
                with self.assertRaises(RuntimeError):
                    cmd_install_default_deps(ctx)


if __name__ == "__main__":
    unittest.main()
