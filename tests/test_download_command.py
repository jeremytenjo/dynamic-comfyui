from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from dynamic_comfyui_runtime.runtime.download import download_url_to_current_directory, filename_from_url


class DownloadCommandTests(unittest.TestCase):
    def test_filename_from_url_ignores_query_string(self) -> None:
        name = filename_from_url(
            "https://huggingface.co/jeremyhola/LORAs/resolve/main/redcraft.safetensors?download=true"
        )
        self.assertEqual(name, "redcraft.safetensors")

    def test_download_uses_env_hf_token_and_urllib_backend(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            previous_cwd = Path.cwd()
            os.chdir(tmp)
            calls: list[tuple[str | None, str | None]] = []

            def fake_download_file(url: str, target: Path, *, hf_token=None, on_progress=None, backend=None) -> None:
                _ = url
                calls.append((hf_token, backend))
                target.write_bytes(b"ok")
                if on_progress:
                    on_progress(2, 2)

            try:
                with (
                    patch.dict(os.environ, {"HF_TOKEN": "env-token"}, clear=False),
                    patch("dynamic_comfyui_runtime.runtime.download.probe_remote_file_size", return_value=2),
                    patch("dynamic_comfyui_runtime.runtime.download.download_file", side_effect=fake_download_file),
                    patch("dynamic_comfyui_runtime.runtime.download.hf_url_requires_token") as requires_token,
                ):
                    target = download_url_to_current_directory(
                        "https://huggingface.co/example/repo/resolve/main/model.safetensors"
                    )
            finally:
                os.chdir(previous_cwd)

        self.assertEqual(target.name, "model.safetensors")
        self.assertEqual(calls, [("env-token", "urllib")])
        requires_token.assert_not_called()

    def test_hf_401_prompts_and_retries_with_token(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            previous_cwd = Path.cwd()
            os.chdir(tmp)
            tokens: list[str | None] = []

            def fake_download_file(url: str, target: Path, *, hf_token=None, on_progress=None, backend=None) -> None:
                _ = (url, on_progress, backend)
                tokens.append(hf_token)
                if len(tokens) == 1:
                    raise RuntimeError("Download failed (401)")
                target.write_bytes(b"ok")

            try:
                with (
                    patch.dict(os.environ, {}, clear=True),
                    patch("dynamic_comfyui_runtime.runtime.download.probe_remote_file_size", return_value=2),
                    patch("dynamic_comfyui_runtime.runtime.download.hf_url_requires_token", return_value=False),
                    patch("dynamic_comfyui_runtime.runtime.download.prompt_text", return_value="prompt-token"),
                    patch("dynamic_comfyui_runtime.runtime.download.download_file", side_effect=fake_download_file),
                ):
                    target = download_url_to_current_directory(
                        "https://huggingface.co/example/repo/resolve/main/model.safetensors"
                    )
            finally:
                os.chdir(previous_cwd)

        self.assertEqual(target.name, "model.safetensors")
        self.assertEqual(tokens, [None, "prompt-token"])


if __name__ == "__main__":
    unittest.main()
