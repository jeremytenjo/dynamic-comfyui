from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from dynamic_comfyui_runtime.runtime import manifests


def _write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload), encoding="utf-8")


class ManifestImportsTests(unittest.TestCase):
    def test_import_projects_requires_project_url_only(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            project_manifest = root / "project.json"
            default_manifest = root / "default.json"
            _write_json(
                project_manifest,
                {
                    "import_projects": [{"project_url": "https://example.com/a.json", "name": "not-allowed"}],
                    "custom_nodes": [],
                    "files": [],
                },
            )
            _write_json(default_manifest, {"custom_nodes": [], "files": []})

            with self.assertRaises(ValueError):
                manifests.merge_manifests(project_manifest, default_manifest, temp_dir=root / "tmp")

    def test_invalid_import_project_url_fails_validation(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            project_manifest = root / "project.json"
            default_manifest = root / "default.json"
            _write_json(
                project_manifest,
                {
                    "import_projects": [{"project_url": "ftp://example.com/a.json"}],
                    "custom_nodes": [],
                    "files": [],
                },
            )
            _write_json(default_manifest, {"custom_nodes": [], "files": []})

            with self.assertRaises(ValueError):
                manifests.merge_manifests(project_manifest, default_manifest, temp_dir=root / "tmp")

    def test_recursive_imports_and_precedence(self) -> None:
        remote = {
            "https://example.com/base.json": {
                "custom_nodes": [{"repo_dir": "SharedNode", "repo": "https://example.com/shared-base.git"}],
                "files": [{"url": "https://example.com/shared-base.bin", "target": "models/shared.bin"}],
            },
            "https://example.com/a.json": {
                "import_projects": [{"project_url": "https://example.com/base.json"}],
                "custom_nodes": [{"repo_dir": "SharedNode", "repo": "https://example.com/shared-a.git"}],
                "files": [{"url": "https://example.com/shared-a.bin", "target": "models/shared.bin"}],
            },
            "https://example.com/c.json": {
                "custom_nodes": [{"repo_dir": "SharedNode", "repo": "https://example.com/shared-c.git"}],
                "files": [{"url": "https://example.com/shared-c.bin", "target": "models/shared.bin"}],
            },
        }

        def fake_download(url: str, target: Path, *, hf_token: str | None = None) -> None:
            _ = hf_token
            payload = remote.get(url)
            if payload is None:
                raise RuntimeError(f"missing fixture for {url}")
            _write_json(target, payload)

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            project_manifest = root / "project.json"
            default_manifest = root / "default.json"
            _write_json(
                project_manifest,
                {
                    "import_projects": [
                        {"project_url": "https://example.com/a.json"},
                        {"project_url": "https://example.com/c.json"},
                    ],
                    "custom_nodes": [{"repo_dir": "SharedNode", "repo": "https://example.com/shared-root.git"}],
                    "files": [{"url": "https://example.com/shared-root.bin", "target": "models/shared.bin"}],
                },
            )
            _write_json(
                default_manifest,
                {"custom_nodes": [{"repo_dir": "DefaultNode", "repo": "https://example.com/default.git"}], "files": []},
            )

            with patch.object(manifests, "download_file", side_effect=fake_download):
                merged = manifests.merge_manifests(project_manifest, default_manifest, temp_dir=root / "tmp")

            project_nodes = {node.repo_dir: node.repo for node in merged.project_custom_nodes}
            project_files = {f.target: f.url for f in merged.project_files}
            merged_nodes = {node.repo_dir: node.repo for node in merged.merged_custom_nodes}
            self.assertEqual(project_nodes["SharedNode"], "https://example.com/shared-root.git")
            self.assertEqual(project_files["models/shared.bin"], "https://example.com/shared-root.bin")
            self.assertIn("DefaultNode", merged_nodes)

    def test_cycle_detection_warns_and_continues(self) -> None:
        remote = {
            "https://example.com/a.json": {
                "import_projects": [{"project_url": "https://example.com/b.json"}],
                "custom_nodes": [{"repo_dir": "NodeA", "repo": "https://example.com/node-a.git"}],
                "files": [],
            },
            "https://example.com/b.json": {
                "import_projects": [{"project_url": "https://example.com/a.json"}],
                "custom_nodes": [{"repo_dir": "NodeB", "repo": "https://example.com/node-b.git"}],
                "files": [],
            },
        }

        def fake_download(url: str, target: Path, *, hf_token: str | None = None) -> None:
            _ = hf_token
            payload = remote.get(url)
            if payload is None:
                raise RuntimeError(f"missing fixture for {url}")
            _write_json(target, payload)

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            project_manifest = root / "project.json"
            _write_json(
                project_manifest,
                {
                    "import_projects": [{"project_url": "https://example.com/a.json"}],
                    "custom_nodes": [],
                    "files": [],
                },
            )

            out = io.StringIO()
            with patch.object(manifests, "download_file", side_effect=fake_download):
                with contextlib.redirect_stdout(out):
                    node_dirs, _ = manifests.resources_for_cleanup(project_manifest)

            self.assertIn("NodeA", node_dirs)
            self.assertIn("NodeB", node_dirs)
            self.assertIn("skipping cyclic imported project manifest", out.getvalue())

    def test_failed_import_is_warning_and_continue(self) -> None:
        remote = {
            "https://example.com/good.json": {
                "custom_nodes": [{"repo_dir": "GoodNode", "repo": "https://example.com/good.git"}],
                "files": [{"url": "https://example.com/good.bin", "target": "models/good.bin"}],
            }
        }

        def fake_download(url: str, target: Path, *, hf_token: str | None = None) -> None:
            _ = hf_token
            payload = remote.get(url)
            if payload is None:
                raise RuntimeError(f"download failed for {url}")
            _write_json(target, payload)

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            project_manifest = root / "project.json"
            _write_json(
                project_manifest,
                {
                    "import_projects": [
                        {"project_url": "https://example.com/good.json"},
                        {"project_url": "https://example.com/missing.json"},
                    ],
                    "custom_nodes": [],
                    "files": [],
                },
            )

            out = io.StringIO()
            with patch.object(manifests, "download_file", side_effect=fake_download):
                with contextlib.redirect_stdout(out):
                    node_dirs, file_targets = manifests.resources_for_cleanup(project_manifest)

            self.assertIn("GoodNode", node_dirs)
            self.assertIn("models/good.bin", file_targets)
            self.assertIn("failed to import project manifest", out.getvalue())

    def test_hf_token_requirement_aggregates_from_imports(self) -> None:
        remote = {
            "https://example.com/private.json": {
                "require_huggingface_token": True,
                "custom_nodes": [],
                "files": [],
            }
        }

        def fake_download(url: str, target: Path, *, hf_token: str | None = None) -> None:
            _ = hf_token
            payload = remote.get(url)
            if payload is None:
                raise RuntimeError(f"missing fixture for {url}")
            _write_json(target, payload)

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            project_manifest = root / "project.json"
            _write_json(
                project_manifest,
                {
                    "require_huggingface_token": False,
                    "import_projects": [{"project_url": "https://example.com/private.json"}],
                    "custom_nodes": [],
                    "files": [],
                },
            )

            with patch.object(manifests, "download_file", side_effect=fake_download):
                requires_token = manifests.project_requires_hf_token(project_manifest)
            self.assertTrue(requires_token)


if __name__ == "__main__":
    unittest.main()
