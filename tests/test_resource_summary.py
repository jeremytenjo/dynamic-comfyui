from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from rich.table import Table

from dynamic_comfyui_runtime.runtime.installer import FileInstallFailure, NodeInstallFailure
from dynamic_comfyui_runtime.runtime.manifests import CustomNode, FileSpec, MergedManifest
from dynamic_comfyui_runtime.runtime.operations import _print_resource_summary


class _CaptureConsole:
    def __init__(self) -> None:
        self.objects: list[object] = []

    def print(self, obj: object) -> None:
        self.objects.append(obj)


class ResourceSummaryTests(unittest.TestCase):
    def test_failure_status_cells_show_error_without_details(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            comfyui_dir = root / "ComfyUI"
            custom_nodes_dir = comfyui_dir / "custom_nodes"
            custom_nodes_dir.mkdir(parents=True)
            capture = _CaptureConsole()
            merged = MergedManifest(
                merged_custom_nodes=[],
                merged_files=[],
                default_custom_nodes=[
                    CustomNode(repo_dir="ComfyUI-Broken", repo="https://example.com/broken-node.git")
                ],
                project_custom_nodes=[],
                default_files=[
                    FileSpec(url="https://example.com/broken.safetensors", target="models/broken.safetensors")
                ],
                project_files=[],
            )

            with (
                patch("dynamic_comfyui_runtime.runtime.operations.console", return_value=capture),
                patch("dynamic_comfyui_runtime.runtime.operations.print_rule"),
                patch("dynamic_comfyui_runtime.runtime.operations._print_failures"),
            ):
                _print_resource_summary(
                    merged,
                    custom_nodes_dir,
                    comfyui_dir,
                    [NodeInstallFailure(repo_dir="ComfyUI-Broken", step="requirements install", error="long node error")],
                    [FileInstallFailure(target="models/broken.safetensors", error="long download error")],
                )

            tables = [obj for obj in capture.objects if isinstance(obj, Table)]
            self.assertEqual(len(tables), 2)
            node_status_cells = tables[0].columns[2]._cells
            file_status_cells = tables[1].columns[2]._cells

            self.assertEqual(node_status_cells[0], "[error]Error[/]")
            self.assertEqual(file_status_cells[0], "[error]Error[/]")
            self.assertNotIn("long node error", node_status_cells[0])
            self.assertNotIn("long download error", file_status_cells[0])


if __name__ == "__main__":
    unittest.main()
