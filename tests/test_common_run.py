from __future__ import annotations

import subprocess
import unittest
from unittest.mock import patch

from dynamic_comfyui_runtime.runtime.common import run


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


if __name__ == "__main__":
    unittest.main()
