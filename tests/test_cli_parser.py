from __future__ import annotations

import unittest

from dynamic_comfyui_runtime.cli import build_parser


class CliParserTests(unittest.TestCase):
    def test_install_default_deps(self) -> None:
        parser = build_parser()
        args = parser.parse_args(["install-default-deps"])
        self.assertEqual(args.command, "install-default-deps")

    def test_set_default_manifest_url_with_arg(self) -> None:
        parser = build_parser()
        args = parser.parse_args(["set-default-manifest-url", "https://example.com/defaults.json"])
        self.assertEqual(args.command, "set-default-manifest-url")
        self.assertEqual(args.manifest_url, "https://example.com/defaults.json")

    def test_set_default_manifest_url_without_arg(self) -> None:
        parser = build_parser()
        args = parser.parse_args(["set-default-manifest-url"])
        self.assertEqual(args.command, "set-default-manifest-url")
        self.assertIsNone(args.manifest_url)

    def test_clear_default_manifest_url(self) -> None:
        parser = build_parser()
        args = parser.parse_args(["clear-default-manifest-url"])
        self.assertEqual(args.command, "clear-default-manifest-url")


if __name__ == "__main__":
    unittest.main()
