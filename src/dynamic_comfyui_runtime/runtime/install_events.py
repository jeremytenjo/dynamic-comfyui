from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True)
class InstallEvent:
    kind: str
    message: str
    target: str | None = None
    status: str | None = None
    downloaded: int | None = None
    total: int | None = None
    error: str | None = None


class InstallEventSink(Protocol):
    def emit(self, event: InstallEvent) -> None:
        ...

    def prompt_secret(self, message: str) -> str:
        ...


class NullInstallEventSink:
    def emit(self, event: InstallEvent) -> None:
        _ = event

    def prompt_secret(self, message: str) -> str:
        _ = message
        return ""
