from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from dynamic_comfyui_runtime.runtime.default_manifest_url import write_default_manifest_url_override
from dynamic_comfyui_runtime.runtime import manifests


def _write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload), encoding="utf-8")


class DefaultManifestResolutionTests(unittest.TestCase):
    def test_no_override_uses_empty_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            resolved = manifests.resolve_default_manifest(root / "package.json", root / "tmp", root)
            data = json.loads(resolved.read_text(encoding="utf-8"))
            self.assertEqual(data, {"custom_nodes": [], "files": []})

    def test_override_download_success(self) -> None:
        def fake_download(url: str, target: Path, *, hf_token: str | None = None) -> None:
            _ = hf_token
            self.assertEqual(url, "https://example.com/defaults.json")
            _write_json(target, {"custom_nodes": [{"repo_dir": "A", "repo": "https://example.com/a.git"}], "files": []})

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            write_default_manifest_url_override(root, "https://example.com/defaults.json")
            with patch.object(manifests, "download_file", side_effect=fake_download):
                resolved = manifests.resolve_default_manifest(root / "package.json", root / "tmp", root)
            data = json.loads(resolved.read_text(encoding="utf-8"))
            self.assertEqual(data["custom_nodes"][0]["repo_dir"], "A")

    def test_override_download_failure_falls_back_to_empty(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            write_default_manifest_url_override(root, "https://example.com/defaults.json")
            with patch.object(manifests, "download_file", side_effect=RuntimeError("boom")):
                resolved = manifests.resolve_default_manifest(root / "package.json", root / "tmp", root)
            data = json.loads(resolved.read_text(encoding="utf-8"))
            self.assertEqual(data, {"custom_nodes": [], "files": []})

    def test_strict_resolver_fails_when_not_configured(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            with self.assertRaises(RuntimeError):
                manifests.resolve_default_manifest_strict(root / "package.json", root / "tmp", root)

    def test_strict_resolver_fails_on_download_error(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            write_default_manifest_url_override(root, "https://example.com/defaults.json")
            with patch.object(manifests, "download_file", side_effect=RuntimeError("boom")):
                with self.assertRaises(RuntimeError):
                    manifests.resolve_default_manifest_strict(root / "package.json", root / "tmp", root)


if __name__ == "__main__":
    unittest.main()
