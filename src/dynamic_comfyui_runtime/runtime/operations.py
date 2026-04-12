from __future__ import annotations

import tempfile
from dataclasses import dataclass
from pathlib import Path

from .common import ensure_dir, now_epoch, require_tools, utc_timestamp
from .installer import (
    FileInstallFailure,
    NodeInstallFailure,
    install_custom_nodes,
    install_files,
    print_custom_nodes_summary,
    print_files_summary,
    remove_project_resources,
)
from .manifests import (
    MergedManifest,
    active_project_manifest_path,
    download_manifest,
    load_project_state,
    merge_manifests,
    normalize_manifest_url,
    project_requires_hf_token,
    resources_for_cleanup,
    resolve_default_manifest,
    save_project_state,
    validate_manifest_url,
    write_empty_manifest,
)
from .progress import mark_done, mark_failed, mark_idle, mark_running, start_setup_page_server
from .service import (
    configure_process_env,
    discover_comfyui_workspace,
    enable_manager_gui,
    ensure_comfy_cli_ready,
    ensure_comfyui_workspace,
    maybe_enable_nodes_setting,
    prepare_network_volume_and_start_jupyter,
    set_model_directories,
    set_network_volume_default,
    start_comfyui_service,
    stop_comfyui_service,
    verify_comfyui_core_workspace,
)
from .updater import uninstall_runtime_package, upgrade_runtime_package


@dataclass
class RuntimeContext:
    network_volume: Path
    package_json_path: Path
    setup_page_html_path: Path
    install_start_ts: int | None = None


@dataclass
class InstallExecution:
    network_volume: Path
    comfyui_dir: Path
    custom_nodes_dir: Path
    merged: MergedManifest
    node_failures: list[NodeInstallFailure]
    file_failures: list[FileInstallFailure]


def _instruction_text() -> str:
    return """Image Generator v1

Requirements:

L40S GPU

First Time Setup:

Save your character lora in the /ComfyUI/models/lora folder.

Usage:

Run this command in the terminal to start ComfyUI. First step: enter your direct JSON URL `dynamic-comfyui start`

Run this command in the terminal to switch projects. First step: enter your direct JSON URL `dynamic-comfyui start-new-project`

Run this command in the terminal to add another project manifest without removing existing resources `dynamic-comfyui add-project`

Run this command in the terminal to replace current project resources with a new project manifest `dynamic-comfyui replace-project`

Run this command in the terminal to restart ComfyUI `dynamic-comfyui restart`

Run this command in the terminal to update nodes and files (uses the last saved JSON URL) `dynamic-comfyui update-nodes-and-models`

Run this command in the terminal to install custom nodes/files only `dynamic-comfyui install-deps <project-json-url>`

Run this command in the terminal to update the dynamic-comfyui runtime package to latest `dynamic-comfyui update-dc`

Run this command in the terminal to uninstall the dynamic-comfyui runtime package `dynamic-comfyui uninstall-dc`

Run this command in the terminal to list available commands `dynamic-comfyui help`
"""


def write_runtime_instructions(network_volume: Path) -> None:
    ensure_dir(network_volume)
    (network_volume / "instructions.txt").write_text(_instruction_text(), encoding="utf-8")


def install_sentinel_path(network_volume: Path) -> Path:
    return network_volume / ".dynamic-comfyui_install_complete"


def verify_install_sentinel(network_volume: Path) -> bool:
    return install_sentinel_path(network_volume).is_file()


def clear_install_sentinel(network_volume: Path) -> None:
    install_sentinel_path(network_volume).unlink(missing_ok=True)


def write_install_sentinel(network_volume: Path, comfyui_dir: Path) -> None:
    install_sentinel_path(network_volume).write_text(
        f"installed_at={utc_timestamp()}\ncomfyui_dir={comfyui_dir}\n",
        encoding="utf-8",
    )


def _prompt_manifest_url() -> str:
    while True:
        raw = input("Enter project URL: ").strip()
        if not raw:
            return ""
        normalized = normalize_manifest_url(raw)
        try:
            validate_manifest_url(normalized)
        except Exception as exc:
            print(f"Invalid URL: {exc}")
            continue
        return normalized


def prompt_and_prepare_project_manifest(network_volume: Path) -> tuple[Path, str]:
    manifest_path = active_project_manifest_path(network_volume)
    while True:
        source_url = _prompt_manifest_url()
        if not source_url:
            write_empty_manifest(manifest_path)
            return manifest_path, ""
        try:
            download_manifest(source_url, manifest_path)
            return manifest_path, source_url
        except Exception as exc:
            print(f"❌ Failed to download project manifest: {exc}")


def prepare_project_manifest(network_volume: Path, source_url: str) -> tuple[Path, str]:
    manifest_path = active_project_manifest_path(network_volume)
    normalized = normalize_manifest_url(source_url.strip())
    validate_manifest_url(normalized)
    download_manifest(normalized, manifest_path)
    return manifest_path, normalized


def _load_manifest_context(ctx: RuntimeContext, project_manifest_path: Path) -> tuple[MergedManifest, str | None]:
    temp_dir = Path(tempfile.mkdtemp(prefix="dynamic-comfyui-install-manifest-"))
    default_manifest_path = resolve_default_manifest(ctx.package_json_path, temp_dir)
    merged = merge_manifests(project_manifest_path, default_manifest_path)

    hf_token: str | None = None
    if project_requires_hf_token(project_manifest_path):
        print("This project manifest requires a Hugging Face token for file downloads.")
        print("Create one at: https://huggingface.co/settings/tokens")
        token = input("Enter your Hugging Face token: ").strip()
        if not token:
            raise RuntimeError("Hugging Face token is required by this project manifest")
        hf_token = token

    return merged, hf_token


def _print_failures(node_failures: list[NodeInstallFailure], file_failures: list[FileInstallFailure]) -> None:
    if node_failures:
        print("❌ Failed custom node installs:")
        for failure in node_failures:
            print(f" - {failure.repo_dir} [{failure.step}] ({failure.error})")

    if file_failures:
        print("❌ Failed file downloads:")
        for failure in file_failures:
            print(f" - {failure.target} ({failure.error})")


def _print_resource_summary(
    merged: MergedManifest,
    custom_nodes_dir: Path,
    comfyui_dir: Path,
    node_failures: list[NodeInstallFailure],
    file_failures: list[FileInstallFailure],
) -> None:
    print_custom_nodes_summary("✅ Installed custom nodes (default resources):", merged.default_custom_nodes, custom_nodes_dir)
    print_custom_nodes_summary("✅ Installed custom nodes (project manifest):", merged.project_custom_nodes, custom_nodes_dir)
    print_files_summary("✅ Installed files (default resources):", merged.default_files, comfyui_dir)
    print_files_summary("✅ Installed files (project manifest):", merged.project_files, comfyui_dir)
    _print_failures(node_failures, file_failures)


def _execute_dependency_install(
    ctx: RuntimeContext, project_manifest_path: Path, *, manager_quiet: bool
) -> InstallExecution:
    network_volume = set_network_volume_default(ctx.network_volume)
    comfyui_dir, custom_nodes_dir = ensure_comfyui_workspace(network_volume)
    set_model_directories(comfyui_dir)
    require_tools(["python3", "git"])

    merged, hf_token = _load_manifest_context(ctx, project_manifest_path)
    mark_running(merged, comfyui_dir)

    print("Ensuring ComfyUI core workspace is installed...")
    ensure_comfy_cli_ready(network_volume)
    verify_comfyui_core_workspace(comfyui_dir)
    enable_manager_gui(comfyui_dir, quiet=manager_quiet)

    print("Ensuring required custom nodes are installed...")
    node_failures = install_custom_nodes(
        merged.merged_custom_nodes, custom_nodes_dir, on_progress=lambda: mark_running(merged, comfyui_dir)
    )

    print("Installing required files...")
    file_failures = install_files(
        merged.merged_files, comfyui_dir, hf_token=hf_token, on_progress=lambda: mark_running(merged, comfyui_dir)
    )

    return InstallExecution(
        network_volume=network_volume,
        comfyui_dir=comfyui_dir,
        custom_nodes_dir=custom_nodes_dir,
        merged=merged,
        node_failures=node_failures,
        file_failures=file_failures,
    )


def run_comfyui_install_flow(ctx: RuntimeContext, project_manifest_path: Path) -> None:
    ctx.install_start_ts = now_epoch()
    clear_install_sentinel(set_network_volume_default(ctx.network_volume))
    execution = _execute_dependency_install(ctx, project_manifest_path, manager_quiet=False)

    write_install_sentinel(execution.network_volume, execution.comfyui_dir)
    startup_lines = start_comfyui_service(
        execution.comfyui_dir, execution.network_volume, install_start_ts=ctx.install_start_ts
    )

    mark_done(execution.merged, execution.comfyui_dir)
    _print_resource_summary(
        execution.merged,
        execution.custom_nodes_dir,
        execution.comfyui_dir,
        execution.node_failures,
        execution.file_failures,
    )
    for line in startup_lines:
        print(line)


def run_dependency_install_flow(ctx: RuntimeContext, project_manifest_path: Path) -> None:
    ctx.install_start_ts = now_epoch()
    execution = _execute_dependency_install(ctx, project_manifest_path, manager_quiet=True)

    mark_done(execution.merged, execution.comfyui_dir)
    _print_resource_summary(
        execution.merged,
        execution.custom_nodes_dir,
        execution.comfyui_dir,
        execution.node_failures,
        execution.file_failures,
    )
    print("Dependency installation complete.")


def cmd_install(ctx: RuntimeContext) -> None:
    configure_process_env()
    network_volume = prepare_network_volume_and_start_jupyter(ctx.network_volume)
    network_volume = set_network_volume_default(network_volume)
    write_runtime_instructions(network_volume)

    comfyui_dir, _custom_nodes_dir = ensure_comfyui_workspace(network_volume)
    maybe_enable_nodes_setting(network_volume)

    mark_idle(None, comfyui_dir)
    start_setup_page_server(ctx.setup_page_html_path)

    print("Jupyter is running.")
    if verify_install_sentinel(network_volume):
        print("Install marker found. Starting ComfyUI...")
        try:
            ensure_comfy_cli_ready(network_volume)
            startup_lines = start_comfyui_service(comfyui_dir, network_volume)
            for line in startup_lines:
                print(line)
        except Exception as exc:
            print(f"Failed to auto-start ComfyUI. Run 'dynamic-comfyui start' from the Jupyter terminal. ({exc})")

    while True:
        import time

        time.sleep(3600)


def _save_selected_project(network_volume: Path, manifest_path: Path, source_url: str) -> None:
    save_project_state(network_volume, "active-project", manifest_path, source_url)
    print("Selected project: active-project")


def cmd_start(ctx: RuntimeContext) -> None:
    configure_process_env()
    network_volume = set_network_volume_default(ctx.network_volume)
    manifest_path, source_url = prompt_and_prepare_project_manifest(network_volume)
    _save_selected_project(network_volume, manifest_path, source_url)
    try:
        run_comfyui_install_flow(ctx, manifest_path)
    except Exception as exc:
        comfyui_dir, _ = ensure_comfyui_workspace(network_volume)
        mark_failed(None, comfyui_dir, f"Installation failed. {exc}")
        raise


def cmd_install_deps(ctx: RuntimeContext, project_url: str | None = None) -> None:
    configure_process_env()
    network_volume = set_network_volume_default(ctx.network_volume)
    detected_comfyui = discover_comfyui_workspace(network_volume)
    if detected_comfyui is not None:
        detected_volume = detected_comfyui.parent
        if detected_volume != network_volume:
            print(f"Detected ComfyUI workspace at {detected_comfyui}. Using {detected_volume} as workspace root.")
        network_volume = detected_volume
    else:
        print(f"Could not auto-detect ComfyUI workspace. Using configured workspace root: {network_volume}")

    if project_url is not None:
        manifest_path, source_url = prepare_project_manifest(network_volume, project_url)
    else:
        manifest_path, source_url = prompt_and_prepare_project_manifest(network_volume)
    _save_selected_project(network_volume, manifest_path, source_url)
    ctx.network_volume = network_volume
    try:
        run_dependency_install_flow(ctx, manifest_path)
    except Exception as exc:
        comfyui_dir, _ = ensure_comfyui_workspace(network_volume)
        mark_failed(None, comfyui_dir, f"Dependency installation failed. {exc}")
        raise


def _snapshot_previous_manifest(network_volume: Path) -> tuple[str, str, Path | None]:
    try:
        previous_key, previous_path, previous_source = load_project_state(network_volume)
    except Exception:
        return "", "", None
    if previous_path.is_file():
        tmp = Path(tempfile.mkstemp(prefix="dynamic-comfyui-previous-project-manifest.", suffix=".json")[1])
        tmp.write_bytes(previous_path.read_bytes())
        return previous_key, previous_source, tmp
    return previous_key, previous_source, None


def _cleanup_previous_resources(snapshot_path: Path, custom_nodes_dir: Path, comfyui_dir: Path) -> None:
    node_dirs, file_targets = resources_for_cleanup(snapshot_path)
    remove_project_resources(node_dirs, file_targets, custom_nodes_dir, comfyui_dir)


def cmd_start_new_project(ctx: RuntimeContext) -> None:
    configure_process_env()
    network_volume = set_network_volume_default(ctx.network_volume)
    previous_key, previous_source, snapshot = _snapshot_previous_manifest(network_volume)

    manifest_path, source_url = prompt_and_prepare_project_manifest(network_volume)
    cleanup_previous = False
    if previous_source and previous_source != source_url:
        print(f"Previous project: {previous_key or 'active-project'}")
        print("Selected project: active-project")
        while True:
            answer = input("Remove resources from previous project? (y/n): ").strip().lower()
            if answer in {"y", "yes"}:
                cleanup_previous = True
                break
            if answer in {"n", "no"}:
                break
            print("Invalid choice. Enter 'y' or 'n'.")

    _save_selected_project(network_volume, manifest_path, source_url)
    run_comfyui_install_flow(ctx, manifest_path)

    if cleanup_previous and snapshot and snapshot.is_file():
        comfyui_dir, custom_nodes_dir = ensure_comfyui_workspace(network_volume)
        _cleanup_previous_resources(snapshot, custom_nodes_dir, comfyui_dir)
        run_comfyui_install_flow(ctx, manifest_path)



def cmd_add_project(ctx: RuntimeContext) -> None:
    cmd_start(ctx)


def cmd_replace_project(ctx: RuntimeContext) -> None:
    configure_process_env()
    network_volume = set_network_volume_default(ctx.network_volume)
    _previous_key, previous_source, snapshot = _snapshot_previous_manifest(network_volume)

    manifest_path, source_url = prompt_and_prepare_project_manifest(network_volume)
    _save_selected_project(network_volume, manifest_path, source_url)
    run_comfyui_install_flow(ctx, manifest_path)

    if snapshot and snapshot.is_file() and previous_source and previous_source != source_url:
        comfyui_dir, custom_nodes_dir = ensure_comfyui_workspace(network_volume)
        _cleanup_previous_resources(snapshot, custom_nodes_dir, comfyui_dir)
        run_comfyui_install_flow(ctx, manifest_path)


def cmd_update_nodes_and_models(ctx: RuntimeContext) -> None:
    configure_process_env()
    network_volume = set_network_volume_default(ctx.network_volume)
    key, _saved_manifest_path, source_url = load_project_state(network_volume)
    manifest_path = active_project_manifest_path(network_volume)

    if source_url:
        source_url = normalize_manifest_url(source_url)
        validate_manifest_url(source_url)
        download_manifest(source_url, manifest_path)
    else:
        write_empty_manifest(manifest_path)

    save_project_state(network_volume, key, manifest_path, source_url)
    run_comfyui_install_flow(ctx, manifest_path)


def cmd_restart(ctx: RuntimeContext) -> None:
    configure_process_env()
    network_volume = set_network_volume_default(ctx.network_volume)
    comfyui_dir, _ = ensure_comfyui_workspace(network_volume)
    ensure_comfy_cli_ready(network_volume)
    print("Restarting ComfyUI...")
    stop_comfyui_service(comfyui_dir)
    startup_lines = start_comfyui_service(comfyui_dir, network_volume)
    for line in startup_lines:
        print(line)
    print("ComfyUI restart complete.")


def cmd_update_dc(_ctx: RuntimeContext) -> None:
    if not upgrade_runtime_package():
        raise RuntimeError("Runtime package update failed")


def cmd_uninstall_dc(_ctx: RuntimeContext) -> None:
    if not uninstall_runtime_package():
        raise RuntimeError("Runtime package uninstall failed")
