from __future__ import annotations

import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from dynamic_comfyui_runtime.runtime.install_events import InstallEvent
from dynamic_comfyui_runtime.runtime.installer import install_files
from dynamic_comfyui_runtime.runtime.manifests import FileSpec


class CapturingEventSink:
    def __init__(self) -> None:
        self.events: list[InstallEvent] = []

    def emit(self, event: InstallEvent) -> None:
        self.events.append(event)

    def prompt_secret(self, message: str) -> str:
        _ = message
        return ""


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

    def test_completion_logs_duration_and_next_file_estimate(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            comfyui_dir = Path(td) / "ComfyUI"
            comfyui_dir.mkdir(parents=True, exist_ok=True)
            specs = [
                FileSpec(url="https://example.com/one.bin", target="models/one.bin"),
                FileSpec(url="https://example.com/two.bin", target="models/two.bin"),
            ]
            info_messages: list[str] = []
            success_messages: list[str] = []

            def fake_probe(url: str, *, hf_token: str | None = None) -> int:
                _ = hf_token
                return 100 if url.endswith("one.bin") else 200

            def fake_download(url: str, target: Path, *, hf_token: str | None = None, on_progress=None) -> None:
                _ = (url, hf_token)
                target.parent.mkdir(parents=True, exist_ok=True)
                size = fake_probe(url)
                if target.name == "two.bin":
                    time.sleep(0.05)
                if on_progress is not None:
                    on_progress(size, size)
                target.write_bytes(b"x" * size)

            with (
                patch("dynamic_comfyui_runtime.runtime.installer.probe_remote_file_size", side_effect=fake_probe),
                patch("dynamic_comfyui_runtime.runtime.installer.effective_free_bytes", return_value=10_000_000),
                patch("dynamic_comfyui_runtime.runtime.installer.download_file", side_effect=fake_download),
                patch("dynamic_comfyui_runtime.runtime.installer.print_info", side_effect=info_messages.append),
                patch("dynamic_comfyui_runtime.runtime.installer.print_success", side_effect=success_messages.append),
            ):
                failures = install_files(specs, comfyui_dir, hf_token=None)

            self.assertEqual(failures, [])
            self.assertTrue(any("completed in " in message for message in success_messages))
            self.assertTrue(
                any(
                    message.startswith("Estimated next download duration for models/two.bin:")
                    for message in info_messages
                )
            )

    def test_remaining_download_snapshot_reports_in_progress_before_first_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            comfyui_dir = Path(td) / "ComfyUI"
            comfyui_dir.mkdir(parents=True, exist_ok=True)
            specs = [
                FileSpec(url="https://example.com/one.bin", target="models/one.bin"),
                FileSpec(url="https://example.com/two.bin", target="models/two.bin"),
            ]
            info_messages: list[str] = []

            def fake_probe(url: str, *, hf_token: str | None = None) -> int:
                _ = hf_token
                return 100 if url.endswith("one.bin") else 200

            def fake_download(url: str, target: Path, *, hf_token: str | None = None, on_progress=None) -> None:
                _ = hf_token
                target.parent.mkdir(parents=True, exist_ok=True)
                if url.endswith("two.bin"):
                    time.sleep(0.05)
                size = fake_probe(url)
                if on_progress is not None and url.endswith("one.bin"):
                    on_progress(size, size)
                target.write_bytes(b"x" * size)

            with (
                patch("dynamic_comfyui_runtime.runtime.installer.probe_remote_file_size", side_effect=fake_probe),
                patch("dynamic_comfyui_runtime.runtime.installer.effective_free_bytes", return_value=10_000_000),
                patch("dynamic_comfyui_runtime.runtime.installer.download_file", side_effect=fake_download),
                patch("dynamic_comfyui_runtime.runtime.installer.print_info", side_effect=info_messages.append),
            ):
                failures = install_files(specs, comfyui_dir, hf_token=None)

            self.assertEqual(failures, [])
            self.assertTrue(any("models/two.bin: in progress (200 B total)" in message for message in info_messages))
            self.assertFalse(any("models/two.bin: 0 B/200 B" in message for message in info_messages))

    def test_event_sink_receives_each_download_progress_callback(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            comfyui_dir = Path(td) / "ComfyUI"
            comfyui_dir.mkdir(parents=True, exist_ok=True)
            spec = FileSpec(url="https://example.com/file.bin", target="models/file.bin")
            sink = CapturingEventSink()

            def fake_download(url: str, target: Path, *, hf_token: str | None = None, on_progress=None) -> None:
                _ = (url, hf_token)
                target.parent.mkdir(parents=True, exist_ok=True)
                if on_progress is not None:
                    on_progress(25, 100)
                    on_progress(50, 100)
                    on_progress(75, 100)
                target.write_bytes(b"x" * 100)

            with (
                patch("dynamic_comfyui_runtime.runtime.installer.probe_remote_file_size", return_value=100),
                patch("dynamic_comfyui_runtime.runtime.installer.effective_free_bytes", return_value=10_000_000),
                patch("dynamic_comfyui_runtime.runtime.installer.download_file", side_effect=fake_download),
            ):
                failures = install_files([spec], comfyui_dir, hf_token=None, event_sink=sink)

            self.assertEqual(failures, [])
            progress_events = [
                event
                for event in sink.events
                if event.kind == "download"
                and event.target == "models/file.bin"
                and event.status == "in progress"
            ]
            self.assertEqual([event.downloaded for event in progress_events], [25, 50, 75])
            self.assertEqual([event.total for event in progress_events], [100, 100, 100])


if __name__ == "__main__":
    unittest.main()
