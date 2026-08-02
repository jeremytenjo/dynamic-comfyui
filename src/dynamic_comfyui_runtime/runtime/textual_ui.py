from __future__ import annotations

import json
import os
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TypeVar

from .common import format_size_for_display
from .install_events import InstallEvent, InstallEventSink
from .progress import PROGRESS_FILE
from .service import resolve_runpod_proxy_url
from .ui import is_interactive_terminal, print_info

T = TypeVar("T")


class TextualUnavailableError(RuntimeError):
    pass


def textual_available() -> bool:
    try:
        import textual  # noqa: F401
    except Exception:
        return False
    return True


def should_use_textual() -> bool:
    return is_interactive_terminal() and textual_available()


def _require_textual() -> None:
    if not textual_available():
        raise TextualUnavailableError("Textual is not installed. Install the runtime package dependencies, then retry.")


def _progress_label(downloaded: int | None, total: int | None) -> str:
    if downloaded is None:
        return "-"
    if total and total > 0:
        percent = int((downloaded * 100) / total)
        return f"{percent}% {format_size_for_display(downloaded)}/{format_size_for_display(total)}"
    return f"{format_size_for_display(downloaded)} downloaded"


def _elapsed_label(started_at: float) -> str:
    elapsed = max(0, int(time.monotonic() - started_at))
    hours, remainder = divmod(elapsed, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def _node_display_name(target: str) -> str:
    return target.removeprefix("custom_nodes/")


def _node_detail(event: InstallEvent) -> str:
    if event.kind == "node_plan":
        return event.message
    _prefix, separator, detail = event.message.partition(": ")
    if separator:
        detail = detail.split(" (", 1)[0]
        return detail
    return event.message


def _register_tenjo_theme(app: object) -> None:
    from textual.theme import Theme

    tenjo_theme = Theme(
        name="tenjo",
        primary="#6750A4",
        secondary="#625B71",
        accent="#7D5260",
        foreground="#1C1B1F",
        background="#FFFBFE",
        surface="#FFFBFE",
        panel="#F7F2FA",
        success="#2E7D32",
        warning="#ED6C02",
        error="#B3261E",
        dark=False,
        variables={
            "block-cursor-background": "#6750A4",
            "block-cursor-foreground": "#FFFFFF",
            "footer-key-foreground": "#6750A4",
            "input-selection-background": "#6750A4 35%",
            "link-color": "#6750A4",
            "scrollbar-color": "#CAC4D0",
            "scrollbar-color-hover": "#6750A4",
        },
    )
    app.register_theme(tenjo_theme)  # type: ignore[attr-defined]
    app.theme = "tenjo"  # type: ignore[attr-defined]


@dataclass
class _WorkerResult:
    value: object | None = None
    error: BaseException | None = None


def run_install_tui(title: str, worker: Callable[[InstallEventSink], T]) -> T:
    _require_textual()

    from textual.app import App, ComposeResult
    from textual.containers import Horizontal, Vertical
    from textual.screen import ModalScreen
    from textual.widgets import Button, DataTable, Footer, MaskedInput, Static

    class _SecretPrompt(ModalScreen[str]):
        CSS = """
        _SecretPrompt {
            align: center middle;
        }

        #prompt {
            width: 72;
            height: auto;
            padding: 1 2;
            border: solid $accent;
            background: $surface;
        }

        #prompt-message {
            height: 3;
        }

        #prompt-actions {
            height: 3;
        }
        """

        def __init__(self, message: str) -> None:
            super().__init__()
            self._message = message

        def compose(self) -> ComposeResult:
            with Vertical(id="prompt"):
                yield Static(self._message, id="prompt-message")
                yield MaskedInput("x" * 256, placeholder="Enter token", id="secret-input", valid_empty=True)
                with Horizontal(id="prompt-actions"):
                    yield Button("Submit", variant="primary", id="submit")
                    yield Button("Cancel", id="cancel")

        def on_button_pressed(self, event: Button.Pressed) -> None:
            if event.button.id == "cancel":
                self.dismiss("")
                return
            self.dismiss(self.query_one("#secret-input", MaskedInput).value)

    class _TextualSink:
        def __init__(self, app: "_InstallApp") -> None:
            self._app = app

        def emit(self, event: InstallEvent) -> None:
            self._app.call_from_thread(self._app.handle_install_event, event)

        def prompt_secret(self, message: str) -> str:
            return self._app.prompt_secret(message)

    class _InstallApp(App[_WorkerResult]):
        AUTO_FOCUS = ""
        CSS = """
        Screen {
            layout: vertical;
        }

        #body {
            height: 1fr;
            padding: 0 1 1 1;
        }

        #install-title-row {
            height: 1;
        }

        #install-title {
            width: 1fr;
            text-style: bold;
        }

        #install-timer {
            width: 18;
            text-style: bold;
            text-align: right;
            color: $primary;
        }

        .panel {
            border: solid $accent;
            padding: 1;
        }

        .panel-title {
            height: 1;
            text-style: bold;
        }

        #main-panels {
            height: 1fr;
        }

        #files-panel {
            height: 1fr;
        }

        #nodes-panel {
            height: 12;
        }

        #errors-panel {
            height: 7;
        }

        #downloads {
            height: 1fr;
        }

        #nodes {
            height: 1fr;
        }

        #errors {
            height: 1fr;
        }
        """
        def __init__(self) -> None:
            super().__init__()
            self._download_row_keys: dict[str, object] = {}
            self._node_row_keys: dict[str, object] = {}
            self._error_count = 0
            self._started_at = time.monotonic()
            self._result = _WorkerResult()

        def compose(self) -> ComposeResult:
            with Vertical(id="body"):
                with Horizontal(id="install-title-row"):
                    yield Static(title, id="install-title")
                    yield Static("00:00:00", id="install-timer")
                with Vertical(id="main-panels"):
                    with Vertical(id="nodes-panel", classes="panel"):
                        yield Static("Custom Nodes", classes="panel-title")
                        yield DataTable(id="nodes")
                    with Vertical(id="files-panel", classes="panel"):
                        yield Static("Files", classes="panel-title")
                        yield DataTable(id="downloads")
                with Vertical(id="errors-panel", classes="panel"):
                    yield Static("Errors (0)", id="errors-title", classes="panel-title")
                    yield DataTable(id="errors")
            yield Footer()

        def on_mount(self) -> None:
            _register_tenjo_theme(self)
            downloads = self.query_one("#downloads", DataTable)
            downloads.add_column("File", key="target", width=70)
            downloads.add_column("Status", key="status", width=14)
            downloads.add_column("Progress", key="progress", width=26)
            downloads.add_column("Source", key="source")
            nodes = self.query_one("#nodes", DataTable)
            nodes.add_column("Custom Node", key="target", width=40)
            nodes.add_column("Status", key="status", width=22)
            nodes.add_column("Source / Detail", key="detail")
            errors = self.query_one("#errors", DataTable)
            errors.add_column("Target", key="target")
            errors.add_column("Error", key="error")
            self.set_interval(1, self._update_elapsed_timer)
            thread = threading.Thread(target=self._run_worker, name="dynamic-comfyui-textual-worker", daemon=True)
            thread.start()

        def _run_worker(self) -> None:
            try:
                self._result.value = worker(_TextualSink(self))
            except BaseException as exc:  # noqa: BLE001
                self._result.error = exc
                self.call_from_thread(self.handle_install_event, InstallEvent(kind="error", message=str(exc), error=str(exc)))
            finally:
                self.call_from_thread(self.exit, self._result)

        def handle_install_event(self, event: InstallEvent) -> None:
            if event.kind == "error":
                self._append_error(event)
            if not event.target:
                return
            if event.kind in {"node", "node_plan"} or event.target.startswith("custom_nodes/"):
                self._update_node(event)
                return
            self._update_download(event)

        def _update_download(self, event: InstallEvent) -> None:
            table = self.query_one("#downloads", DataTable)
            status = event.status or event.kind
            progress = _progress_label(event.downloaded, event.total)
            if event.target not in self._download_row_keys:
                self._download_row_keys[event.target] = table.add_row(event.target, status, progress, event.message)
            else:
                row_key = self._download_row_keys[event.target]
                table.update_cell(row_key, "status", status)
                table.update_cell(row_key, "progress", progress)
                if event.kind == "file_plan":
                    table.update_cell(row_key, "source", event.message)

        def _update_elapsed_timer(self) -> None:
            self.query_one("#install-timer", Static).update(_elapsed_label(self._started_at))

        def _update_node(self, event: InstallEvent) -> None:
            if event.target is None:
                return
            table = self.query_one("#nodes", DataTable)
            status = event.status or event.kind
            target = _node_display_name(event.target)
            detail = _node_detail(event)
            if event.target not in self._node_row_keys:
                self._node_row_keys[event.target] = table.add_row(target, status, detail)
                return
            row_key = self._node_row_keys[event.target]
            table.update_cell(row_key, "target", target)
            table.update_cell(row_key, "status", status)
            table.update_cell(row_key, "detail", detail)

        def _append_error(self, event: InstallEvent) -> None:
            table = self.query_one("#errors", DataTable)
            self._error_count += 1
            table.add_row(event.target or "-", event.error or event.message)
            self.query_one("#errors-title", Static).update(f"Errors ({self._error_count})")

        def prompt_secret(self, message: str) -> str:
            result: list[str] = []
            dismissed = threading.Event()

            def _on_dismiss(value: str) -> None:
                result.append(value)
                dismissed.set()

            self.call_from_thread(self.push_screen, _SecretPrompt(message), _on_dismiss)
            dismissed.wait()
            return result[0] if result else ""

    result = _InstallApp().run()
    if result is None:
        raise RuntimeError("Textual install UI exited before the command completed")
    if result.error is not None:
        raise result.error
    return result.value  # type: ignore[return-value]


def run_monitor_tui(progress_file: Path = PROGRESS_FILE) -> None:
    _require_textual()

    from textual.app import App, ComposeResult
    from textual.widgets import DataTable, DirectoryTree, Footer, Header, Static, TabbedContent, TabPane

    def _resource_tree_path() -> Path:
        network_volume = Path(os.environ.get("NETWORK_VOLUME", "/workspace"))
        comfyui_dir = network_volume / "ComfyUI"
        if comfyui_dir.is_dir():
            return comfyui_dir
        if network_volume.is_dir():
            return network_volume
        return Path.cwd()

    class _MonitorApp(App[None]):
        AUTO_FOCUS = ""
        CSS = """
        Screen {
            layout: vertical;
        }

        #status {
            height: 3;
            padding: 0 1;
        }

        #monitor-tabs {
            height: 1fr;
        }
        """
        BINDINGS = [("q", "quit", "Quit"), ("r", "refresh", "Refresh")]

        def compose(self) -> ComposeResult:
            yield Header(show_clock=True)
            yield Static("Waiting for setup progress...", id="status")
            with TabbedContent(initial="resources", id="monitor-tabs"):
                with TabPane("Resources", id="resources"):
                    yield DataTable(id="items")
                with TabPane("Files", id="files"):
                    yield DirectoryTree(_resource_tree_path(), id="resource-tree")
            yield Footer()

        def on_mount(self) -> None:
            _register_tenjo_theme(self)
            table = self.query_one("#items", DataTable)
            table.add_column("Source")
            table.add_column("Kind")
            table.add_column("Target")
            table.add_column("Status")
            self.set_interval(1.0, self.refresh_progress)
            self.refresh_progress()

        def action_refresh(self) -> None:
            self.refresh_progress()

        def refresh_progress(self) -> None:
            status = self.query_one("#status", Static)
            table = self.query_one("#items", DataTable)
            if not progress_file.is_file():
                status.update(f"No progress file yet: {progress_file}")
                table.clear()
                return
            try:
                payload = json.loads(progress_file.read_text(encoding="utf-8"))
            except Exception as exc:  # noqa: BLE001
                status.update(f"Could not read progress: {exc}")
                return

            gui_url = resolve_runpod_proxy_url(8188) or "http://127.0.0.1:8188"
            status.update(f"{payload.get('status', 'unknown')}: {payload.get('message', '')}\nComfyUI: {gui_url}")
            table.clear()
            groups = payload.get("groups", {})
            for source_key in ("default", "project"):
                group = groups.get(source_key, {})
                for item in group.get("items", []):
                    checked = bool(item.get("checked"))
                    table.add_row(
                        str(item.get("source", source_key)),
                        str(item.get("kind", "-")),
                        str(item.get("target", "-")),
                        "ready" if checked else "missing",
                    )

    _MonitorApp().run()


def cmd_monitor() -> None:
    if not textual_available():
        print_info("Textual is not installed; install package dependencies and retry `dc monitor`.")
        return
    run_monitor_tui()
