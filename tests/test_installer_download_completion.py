from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from dynamic_comfyui_runtime.runtime.installer import install_files
from dynamic_comfyui_runtime.runtime.manifests import FileSpec


class InstallerDownloadCompletionTests(unittest.TestCase):
    def test_stale_progress_snapshot_but_full_file_is_success(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            comfyui_dir = Path(td) / "ComfyUI"
            comfyui_dir.mkdir(parents=True, exist_ok=True)
            spec = FileSpec(url="https://example.com/file.bin", target="models/file.bin")

            def fake_download(url: str, target: Path, *, hf_token: str | None = None, on_progress=None) -> None:
                _ = (url, hf_token)
                target.parent.mkdir(parents=True, exist_ok=True)
                if on_progress is not None:
                    on_progress(10, 100)
                target.write_bytes(b"x" * 100)

            with (
                patch("dynamic_comfyui_runtime.runtime.installer.probe_remote_file_size", return_value=100),
                patch("dynamic_comfyui_runtime.runtime.installer.effective_free_bytes", return_value=10_000_000),
                patch("dynamic_comfyui_runtime.runtime.installer.download_file", side_effect=fake_download),
            ):
                failures = install_files([spec], comfyui_dir, hf_token=None)

            self.assertEqual(failures, [])

    def test_incomplete_file_size_is_failure(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            comfyui_dir = Path(td) / "ComfyUI"
            comfyui_dir.mkdir(parents=True, exist_ok=True)
            spec = FileSpec(url="https://example.com/file.bin", target="models/file.bin")

            def fake_download(url: str, target: Path, *, hf_token: str | None = None, on_progress=None) -> None:
                _ = (url, hf_token)
                target.parent.mkdir(parents=True, exist_ok=True)
                if on_progress is not None:
                    on_progress(10, 100)
                target.write_bytes(b"x" * 10)

            with (
                patch("dynamic_comfyui_runtime.runtime.installer.probe_remote_file_size", return_value=100),
                patch("dynamic_comfyui_runtime.runtime.installer.effective_free_bytes", return_value=10_000_000),
                patch("dynamic_comfyui_runtime.runtime.installer.download_file", side_effect=fake_download),
            ):
                failures = install_files([spec], comfyui_dir, hf_token=None)

            self.assertEqual(len(failures), 1)
            self.assertEqual(failures[0].target, "models/file.bin")


if __name__ == "__main__":
    unittest.main()
