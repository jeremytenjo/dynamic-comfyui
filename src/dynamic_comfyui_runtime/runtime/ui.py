from __future__ import annotations

import logging
import sys
from contextlib import contextmanager
from typing import Iterator

from rich.console import Console
from rich.logging import RichHandler
from rich.panel import Panel
from rich.prompt import Confirm, Prompt
from rich.rule import Rule
from rich.theme import Theme
from rich.traceback import install as install_rich_traceback

_THEME = Theme(
    {
        "info": "default",
        "success": "green",
        "warning": "yellow",
        "error": "bold red",
        "muted": "default",
        "url": "bright_blue underline",
        "phase": "default",
        "progress.download": "default",
    }
)

_console = Console(theme=_THEME)


def console() -> Console:
    return _console


def setup_rich_runtime() -> None:
    install_rich_traceback(show_locals=False, suppress=["rich"])
    root_logger = logging.getLogger()
    if root_logger.handlers:
        return
    logging.basicConfig(
        level=logging.INFO,
        format="%(message)s",
        handlers=[RichHandler(console=_console, rich_tracebacks=True, show_path=False, show_level=False, show_time=False)],
    )


def print_info(message: str) -> None:
    _console.print(f"[info]{message}[/]")


def print_success(message: str) -> None:
    _console.print(f"[success]{message}[/]")


def print_warning(message: str) -> None:
    _console.print(f"[warning]{message}[/]")


def print_error(message: str) -> None:
    _console.print(f"[error]{message}[/]")


def print_rule(title: str) -> None:
    _console.print(Rule(title, style="default"))


def print_panel(message: str, *, title: str | None = None, style: str = "info") -> None:
    _console.print(Panel.fit(message, title=title, border_style=style))


@contextmanager
def status(message: str, *, spinner: str = "dots") -> Iterator[None]:
    with _console.status(message, spinner=spinner):
        yield


def prompt_text(message: str, *, password: bool = False, default: str | None = None) -> str:
    return Prompt.ask(message, password=password, default=default)


def prompt_confirm(message: str, *, default: bool = False) -> bool:
    return Confirm.ask(message, default=default)


def is_interactive_terminal() -> bool:
    return bool(sys.stdout.isatty() and sys.stderr.isatty())
