from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

from .common import run
from .ui import print_info, prompt_confirm


@dataclass(frozen=True)
class InstallCompleteHook:
    commands: list[str]


@dataclass(frozen=True)
class ManifestHooks:
    on_install_complete: InstallCompleteHook | None = None


@dataclass(frozen=True)
class HookedManifest:
    source_url: str
    hooks: ManifestHooks


def validate_no_overriding_hook_conflicts(manifests: list[HookedManifest]) -> None:
    hook_sources: dict[str, list[str]] = defaultdict(list)
    for manifest in manifests:
        if manifest.hooks.on_install_complete is not None:
            hook_sources["on_install_complete"].append(manifest.source_url)

    conflicts = {hook_name: urls for hook_name, urls in hook_sources.items() if len(urls) > 1}
    if not conflicts:
        return

    details: list[str] = []
    for hook_name in sorted(conflicts):
        urls = ", ".join(conflicts[hook_name])
        details.append(f"{hook_name}: {urls}")
    raise RuntimeError(
        "Conflicting overriding hooks found across selected project manifests. "
        "Only one manifest may define each overriding hook per install-deps run. "
        + "Conflicts: "
        + "; ".join(details)
    )


def collect_on_install_complete_commands(manifests: list[HookedManifest]) -> list[str]:
    commands: list[str] = []
    for manifest in manifests:
        hook = manifest.hooks.on_install_complete
        if hook is None:
            continue
        commands.extend(hook.commands)
    return commands


def confirm_and_run_on_install_complete_commands(commands: list[str], *, cwd: Path | None = None) -> None:
    if not commands:
        return
    if not prompt_confirm("Run on_install_complete commands now?", default=False):
        print_info("Skipped on_install_complete commands.")
        return

    for index, command in enumerate(commands, start=1):
        print_info(f"Running on_install_complete command [{index}/{len(commands)}]: {command}")
        try:
            run(["bash", "-lc", command], cwd=cwd, quiet=True)
        except Exception as exc:
            raise RuntimeError(f"on_install_complete command failed: {command} ({exc})") from exc


def run_on_install_complete_commands(commands: list[str], *, cwd: Path | None = None) -> None:
    if not commands:
        return
    for index, command in enumerate(commands, start=1):
        print_info(f"Running on_install_complete command [{index}/{len(commands)}]: {command}")
        try:
            run(["bash", "-lc", command], cwd=cwd, quiet=True)
        except Exception as exc:
            raise RuntimeError(f"on_install_complete command failed: {command} ({exc})") from exc
