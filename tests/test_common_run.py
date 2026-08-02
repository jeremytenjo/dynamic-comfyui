from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from dynamic_comfyui_runtime.runtime.common import _download_file_with_wget, run


class CommonRunTests(unittest.TestCase):
    def test_timeout_error_decodes_byte_output(self) -> None:
        timeout_exc = subprocess.TimeoutExpired(
            cmd=["comfy", "launch"],
            timeout=60,
            output=b"\xe2\x94\x80 launch output",
            stderr=b"\xe2\x94\x82 stderr output",
        )

        with patch("dynamic_comfyui_runtime.runtime.common.subprocess.run", side_effect=timeout_exc):
            with self.assertRaises(RuntimeError) as raised:
                run(["comfy", "launch"], timeout=60)

        message = str(raised.exception)
        self.assertIn("Command timed out after 60s", message)
        self.assertNotIn("b'\\xe2", message)
        self.assertIn("launch output", message)
        self.assertIn("stderr output", message)

    def test_wget_download_reports_progress_while_process_is_running(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            target = Path(td) / "model.bin"
            progress: list[tuple[int, int | None]] = []

            class FakePopen:
                returncode = 0

                def __init__(self, cmd: list[str], **kwargs: object) -> None:
                    _ = kwargs
                    self._target = Path(cmd[cmd.index("-O") + 1])
                    self._poll_count = 0

                def poll(self) -> int | None:
                    self._poll_count += 1
                    if self._poll_count == 1:
                        self._target.write_bytes(b"x" * 10)
                        return None
                    if self._poll_count == 2:
                        self._target.write_bytes(b"x" * 50)
                        return None
                    self._target.write_bytes(b"x" * 100)
                    return 0

                def communicate(self) -> tuple[str, str]:
                    return "", ""

            with (
                patch("dynamic_comfyui_runtime.runtime.common.ensure_wget_available", return_value=True),
                patch("dynamic_comfyui_runtime.runtime.common.probe_remote_file_size", return_value=100),
                patch("dynamic_comfyui_runtime.runtime.common.effective_free_bytes", return_value=1_000),
                patch("dynamic_comfyui_runtime.runtime.common.subprocess.Popen", side_effect=FakePopen),
                patch("dynamic_comfyui_runtime.runtime.common.time.sleep"),
            ):
                _download_file_with_wget(
                    "https://example.com/model.bin",
                    target,
                    on_progress=lambda downloaded, total: progress.append((downloaded, total)),
                )

            self.assertEqual(progress, [(10, 100), (50, 100), (100, 100)])


if __name__ == "__main__":
    unittest.main()
