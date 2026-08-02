from __future__ import annotations

import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

from rich.table import Table

from dynamic_comfyui_runtime.runtime.manifests import CustomNode, FileSpec, MergedManifest
from dynamic_comfyui_runtime.runtime.operations import (
    RuntimeContext,
    _emit_install_plan_events,
    _print_install_plan_preview,
    run_comfyui_install_flow_foreground,
)
from dynamic_comfyui_runtime.runtime.start_deferred_downloads import split_start_deferred_files


class CapturingConsole:
    def __init__(self) -> None:
        self.printed: list[object] = []

    def print(self, item: object) -> None:
        self.printed.append(item)


class CapturingEventSink:
    def __init__(self) -> None:
        self.events: list[object] = []

    def emit(self, event: object) -> None:
        self.events.append(event)

    def prompt_secret(self, message: str) -> str:
        _ = message
        return ""


class StartDeferredDownloadsTests(unittest.TestCase):
    def _merged(self) -> MergedManifest:
        normal = FileSpec(url="https://example.com/normal.bin", target="models/normal.bin")
        deferred = FileSpec(
            url="https://example.com/deferred.bin",
            target="models/deferred.bin",
            start_comfyui_before_downloading=True,
        )
        return MergedManifest(
            merged_custom_nodes=[CustomNode(repo_dir="ComfyUI-Test", repo="https://example.com/test.git")],
            merged_files=[normal, deferred],
            default_custom_nodes=[CustomNode(repo_dir="ComfyUI-Test", repo="https://example.com/test.git")],
            project_custom_nodes=[],
            default_files=[],
            project_files=[normal, deferred],
        )

    def test_split_start_deferred_files_removes_deferred_targets_from_initial_manifest(self) -> None:
        initial, deferred = split_start_deferred_files(self._merged())

        self.assertEqual([spec.target for spec in initial.merged_files], ["models/normal.bin"])
        self.assertEqual([spec.target for spec in initial.project_files], ["models/normal.bin"])
        self.assertEqual([spec.target for spec in deferred], ["models/deferred.bin"])

    def test_install_plan_table_shows_deferred_download_timing_only_when_pending(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            initial, deferred = split_start_deferred_files(self._merged())
            fake_console = CapturingConsole()

            with (
                patch("dynamic_comfyui_runtime.runtime.operations.print_rule"),
                patch("dynamic_comfyui_runtime.runtime.operations.console", return_value=fake_console),
                patch("dynamic_comfyui_runtime.runtime.operations.probe_remote_file_size", return_value=1024),
            ):
                _print_install_plan_preview(initial, root / "custom_nodes", root, None, deferred_files=deferred)

            tables = [item for item in fake_console.printed if isinstance(item, Table)]
            files_table = tables[-1]
            headers = [column.header for column in files_table.columns]
            self.assertEqual(headers, ["File", "Source", "Timing", "Size"])
            timing_cells = files_table.columns[2]._cells
            self.assertIn("Before ComfyUI", timing_cells)
            self.assertIn("After ComfyUI starts", timing_cells)

    def test_install_plan_table_omits_timing_column_without_pending_deferred_downloads(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            initial, deferred = split_start_deferred_files(self._merged())
            deferred_path = root / "models" / "deferred.bin"
            deferred_path.parent.mkdir(parents=True, exist_ok=True)
            deferred_path.write_text("already downloaded", encoding="utf-8")
            fake_console = CapturingConsole()

            with (
                patch("dynamic_comfyui_runtime.runtime.operations.print_rule"),
                patch("dynamic_comfyui_runtime.runtime.operations.console", return_value=fake_console),
                patch("dynamic_comfyui_runtime.runtime.operations.probe_remote_file_size", return_value=1024),
            ):
                _print_install_plan_preview(initial, root / "custom_nodes", root, None, deferred_files=deferred)

            tables = [item for item in fake_console.printed if isinstance(item, Table)]
            files_table = tables[-1]
            headers = [column.header for column in files_table.columns]
            self.assertEqual(headers, ["File", "Source", "Size"])

    def test_install_plan_events_include_pending_nodes_and_files(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            custom_nodes_dir = root / "custom_nodes"
            installed_path = root / "models" / "installed.bin"
            installed_path.parent.mkdir(parents=True, exist_ok=True)
            installed_path.write_bytes(b"x" * 12)
            initial, deferred = split_start_deferred_files(self._merged())
            installed = FileSpec(url="https://example.com/installed.bin", target="models/installed.bin")
            initial = MergedManifest(
                merged_custom_nodes=initial.merged_custom_nodes,
                merged_files=[*initial.merged_files, installed],
                default_custom_nodes=initial.default_custom_nodes,
                project_custom_nodes=initial.project_custom_nodes,
                default_files=initial.default_files,
                project_files=[*initial.project_files, installed],
            )
            sink = CapturingEventSink()

            _emit_install_plan_events(sink, initial, custom_nodes_dir, root, deferred)

            events_by_target = {event.target: event for event in sink.events}
            self.assertEqual(events_by_target["custom_nodes/ComfyUI-Test"].kind, "node_plan")
            self.assertEqual(events_by_target["custom_nodes/ComfyUI-Test"].status, "pending")
            self.assertEqual(events_by_target["models/normal.bin"].kind, "file_plan")
            self.assertEqual(events_by_target["models/normal.bin"].status, "pending")
            self.assertEqual(events_by_target["models/deferred.bin"].kind, "file_plan")
            self.assertEqual(events_by_target["models/deferred.bin"].status, "deferred")
            self.assertEqual(events_by_target["models/installed.bin"].status, "installed")
            self.assertEqual(events_by_target["models/installed.bin"].downloaded, 12)
            self.assertEqual(events_by_target["models/installed.bin"].total, 12)

    def test_foreground_start_launches_deferred_download_after_comfyui_starts(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            comfyui_dir = root / "ComfyUI"
            custom_nodes_dir = comfyui_dir / "custom_nodes"
            manifest_path = root / "project.json"
            ctx = RuntimeContext(
                network_volume=root,
                package_json_path=root / "package.json",
                setup_page_html_path=root / "setup_page.html",
                configured_network_volume=root,
            )
            installed_targets: list[list[str]] = []

            def fake_install_files(files: list[FileSpec], *args, **kwargs):
                _ = args, kwargs
                installed_targets.append([spec.target for spec in files])
                return []

            def fake_start_foreground(*args, **kwargs):
                _ = args
                after_start = kwargs.get("after_start")
                self.assertIsNotNone(after_start)
                after_start()

            with ExitStack() as stack:
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations.set_network_volume_default", return_value=root))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations.clear_install_sentinel"))
                stack.enter_context(patch(
                    "dynamic_comfyui_runtime.runtime.operations.ensure_comfyui_workspace",
                    return_value=(comfyui_dir, custom_nodes_dir),
                ))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations.set_model_directories"))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations.require_tools"))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations._load_manifest_context", return_value=(self._merged(), None)))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations._ensure_hf_token_for_pending_downloads", return_value="hf-token"))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations._print_install_plan_preview"))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations.mark_running"))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations.print_rule"))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations.ensure_comfy_cli_ready"))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations.verify_comfyui_core_workspace"))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations.enable_manager_gui"))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations.install_custom_nodes", return_value=[]))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations.install_files", side_effect=fake_install_files))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations._retry_hf_401_file_downloads", return_value=[]))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations.write_install_sentinel"))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations.mark_done"))
                stack.enter_context(patch("dynamic_comfyui_runtime.runtime.operations._print_resource_summary"))
                start_background = stack.enter_context(patch(
                    "dynamic_comfyui_runtime.runtime.operations.start_background_deferred_file_downloads"
                ))
                stack.enter_context(patch(
                    "dynamic_comfyui_runtime.runtime.operations.start_comfyui_service_foreground",
                    side_effect=fake_start_foreground,
                ))
                run_comfyui_install_flow_foreground(ctx, manifest_path, defer_start_files=True)

            self.assertEqual(installed_targets, [["models/normal.bin"]])
            start_background.assert_called_once()
            self.assertEqual(start_background.call_args.args[0][0].target, "models/deferred.bin")
            self.assertEqual(start_background.call_args.args[1], comfyui_dir)
            self.assertEqual(start_background.call_args.kwargs["hf_token"], "hf-token")


if __name__ == "__main__":
    unittest.main()
