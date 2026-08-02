from __future__ import annotations

import unittest

from dynamic_comfyui_runtime.runtime.banner import project_name_from_manifest_url, render_ascii_banner
from dynamic_comfyui_runtime.runtime.operations import _install_ui_title


class BannerTests(unittest.TestCase):
    def test_project_name_from_manifest_url(self) -> None:
        source_url = "https://github.com/jeremytenjo/avatary-dynamic-comfyui-projects/blob/main/qwen-image-2512.json"
        self.assertEqual(project_name_from_manifest_url(source_url), "qwen-image-2512")

    def test_install_ui_title_uses_manifest_filename(self) -> None:
        source_url = "https://github.com/jeremytenjo/avatary-dynamic-comfyui-projects/blob/main/krea2-image.json"
        self.assertEqual(_install_ui_title(source_url, "Dynamic ComfyUI start"), "krea2-image")

    def test_install_ui_title_uses_fallback_without_source_url(self) -> None:
        self.assertEqual(_install_ui_title("", "Dynamic ComfyUI start"), "Dynamic ComfyUI start")

    def test_project_name_fallback_when_path_empty(self) -> None:
        self.assertEqual(project_name_from_manifest_url("https://example.com/"), "project")

    def test_render_ascii_banner_is_multiline_and_contains_ink(self) -> None:
        banner = render_ascii_banner("qwen-image-2512")
        lines = banner.splitlines()
        self.assertGreater(len(lines), 6)
        self.assertTrue(any(line.strip() for line in lines))


if __name__ == "__main__":
    unittest.main()
