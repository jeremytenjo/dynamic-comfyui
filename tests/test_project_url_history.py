from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from dynamic_comfyui_runtime.runtime.manifests import append_project_url_history, load_project_url_history


class ProjectUrlHistoryTests(unittest.TestCase):
    def test_appends_unique_urls_in_order(self) -> None:
        network_volume = Path(tempfile.mkdtemp(prefix="dynamic-comfyui-test-history-"))
        append_project_url_history(network_volume, "https://example.com/a.json")
        append_project_url_history(network_volume, "https://example.com/b.json")
        append_project_url_history(network_volume, "https://example.com/a.json")
        self.assertEqual(
            load_project_url_history(network_volume),
            ["https://example.com/a.json", "https://example.com/b.json"],
        )


if __name__ == "__main__":
    unittest.main()
