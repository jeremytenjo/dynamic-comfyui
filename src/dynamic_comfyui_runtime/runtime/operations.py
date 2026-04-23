from __future__ import annotations

import tempfile
import urllib.parse
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from rich.table import Table

from .common import ensure_dir, format_size_for_display, now_epoch, probe_remote_file_size, require_tools, utc_timestamp
from .installer import (
    FileInstallFailure,
    NodeInstallFailure,
    install_custom_nodes,
    install_files,
    remove_project_resources,
)
from .manifests import (
    FileSpec,
    MergedManifest,
    active_project_manifest_path,
    download_manifest,
    load_project_state,
    merge_manifests,
    normalize_manifest_url,
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
    start_comfyui_service_for_restart,
    stop_comfyui_service,
    verify_comfyui_core_workspace,
    resolve_runpod_proxy_url,
)
from .system_info import collect_system_info, print_system_info
from .ui import (
    console,
    print_error,
    print_info,
    print_panel,
    print_rule,
    print_success,
    print_warning,
    prompt_confirm,
    prompt_text,
    status,
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

Run this command in the terminal to stop ComfyUI `dynamic-comfyui stop`

Run this command in the terminal to update nodes and files (uses the last saved JSON URL) `dynamic-comfyui update-nodes-and-models`

Run this command in the terminal to install custom nodes/files only `dynamic-comfyui install-deps <project-json-url> [project-json-url ...]`

Run this command in the terminal to remove files only from project manifest URL(s) `dynamic-comfyui remove-deps <project-json-url> [project-json-url ...]`

Run this command in the terminal to update the dynamic-comfyui runtime package to latest `dynamic-comfyui update-dc`

Run this command in the terminal to uninstall the dynamic-comfyui runtime package `dynamic-comfyui uninstall-dc`

Run this command in the terminal to print runtime/GPU versions and memory info `dynamic-comfyui system-info`

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
        raw = prompt_text("Enter project URL").strip()
        if not raw:
            return ""
        normalized = normalize_manifest_url(raw)
        try:
            validate_manifest_url(normalized)
        except Exception as exc:
            print_warning(f"Invalid URL: {exc}")
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
            with status("Downloading project manifest..."):
                download_manifest(source_url, manifest_path)
            return manifest_path, source_url
        except Exception as exc:
            print_error(f"Failed to download project manifest: {exc}")


def prepare_project_manifest(network_volume: Path, source_url: str) -> tuple[Path, str]:
    manifest_path = active_project_manifest_path(network_volume)
    normalized = normalize_manifest_url(source_url.strip())
    validate_manifest_url(normalized)
    with status("Downloading project manifest..."):
        download_manifest(normalized, manifest_path)
    return manifest_path, normalized


def _load_manifest_context(
    ctx: RuntimeContext,
    project_manifest_path: Path,
    *,
    default_manifest_path: Path | None = None,
) -> tuple[MergedManifest, str | None]:
    temp_dir = Path(tempfile.mkdtemp(prefix="dynamic-comfyui-install-manifest-"))
    resolved_default_manifest = default_manifest_path or resolve_default_manifest(ctx.package_json_path, temp_dir)
    merged = merge_manifests(project_manifest_path, resolved_default_manifest, temp_dir=temp_dir)
    return merged, None


def _print_failures(node_failures: list[NodeInstallFailure], file_failures: list[FileInstallFailure]) -> None:
    if node_failures:
        print_error("Failed custom node installs:")
        for failure in node_failures:
            print_error(f" - {failure.repo_dir} [{failure.step}] ({failure.error})")

    if file_failures:
        print_error("Failed file downloads:")
        for failure in file_failures:
            print_error(f" - {failure.target} ({failure.error})")


def _retry_hf_401_file_downloads(
    merged: MergedManifest,
    comfyui_dir: Path,
    file_failures: list[FileInstallFailure],
    *,
    on_progress: callable | None = None,
) -> list[FileInstallFailure]:
    if not file_failures:
        return file_failures

    spec_by_target: dict[str, FileSpec] = {Path(spec.target).as_posix(): spec for spec in merged.merged_files}

    def _is_hf_401(target: str, error: str) -> bool:
        spec = spec_by_target.get(Path(target).as_posix())
        if spec is None:
            return False
        host = urllib.parse.urlparse(spec.url).netloc.lower()
        if "huggingface.co" not in host:
            return False
        return "(401)" in error or " 401" in error or "401 " in error

    hf_401_failures = [failure for failure in file_failures if _is_hf_401(failure.target, failure.error)]
    if not hf_401_failures:
        return file_failures

    print_panel(
        "Some model downloads returned HTTP 401 from Hugging Face.\n"
        "Enter a Hugging Face token to retry the failed downloads.\n"
        "Create one at: [url]https://huggingface.co/settings/tokens[/].",
        title="Hugging Face Token Required",
        style="warning",
    )
    retry_token = prompt_text("Enter your Hugging Face token").strip()
    if not retry_token:
        print_warning("No Hugging Face token provided. Keeping original 401 failures.")
        return file_failures

    retry_specs: list[FileSpec] = []
    seen_targets: set[str] = set()
    for failure in hf_401_failures:
        key = Path(failure.target).as_posix()
        if key in seen_targets:
            continue
        spec = spec_by_target.get(key)
        if spec is None:
            continue
        retry_specs.append(spec)
        seen_targets.add(key)

    if not retry_specs:
        return file_failures

    print_rule("Retry Failed Hugging Face Downloads")
    retry_failures = install_files(
        retry_specs,
        comfyui_dir,
        hf_token=retry_token,
        on_progress=on_progress,
    )

    retried_targets = {Path(spec.target).as_posix() for spec in retry_specs}
    remaining_failures = [failure for failure in file_failures if Path(failure.target).as_posix() not in retried_targets]
    return sorted([*remaining_failures, *retry_failures], key=lambda item: item.target)


def _pending_files_for_download(merged: MergedManifest, comfyui_dir: Path) -> list[FileSpec]:
    pending: list[FileSpec] = []
    seen_targets: set[str] = set()
    for spec in merged.merged_files:
        normalized_target = Path(spec.target).as_posix()
        if normalized_target in seen_targets:
            continue
        seen_targets.add(normalized_target)
        if (comfyui_dir / normalized_target).is_file():
            continue
        pending.append(FileSpec(url=spec.url, target=normalized_target))
    return pending


def _hf_url_requires_token(url: str) -> bool:
    headers = {
        "Accept": "*/*",
        "User-Agent": "dynamic-comfyui-runtime-downloader/1.0",
    }
    try:
        head_req = urllib.request.Request(url, headers=headers, method="HEAD")
        with urllib.request.urlopen(head_req, timeout=20):  # noqa: S310
            return False
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            return True
    except Exception:
        pass

    try:
        range_headers = dict(headers)
        range_headers["Range"] = "bytes=0-0"
        get_req = urllib.request.Request(url, headers=range_headers, method="GET")
        with urllib.request.urlopen(get_req, timeout=20):  # noqa: S310
            return False
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            return True
    except Exception:
        pass
    return False


def _ensure_hf_token_for_pending_downloads(
    merged: MergedManifest,
    comfyui_dir: Path,
    hf_token: str | None,
) -> str | None:
    if hf_token:
        return hf_token

    pending_files = _pending_files_for_download(merged, comfyui_dir)
    hf_urls = []
    for spec in pending_files:
        host = urllib.parse.urlparse(spec.url).netloc.lower()
        if "huggingface.co" in host:
            hf_urls.append(spec.url)
    if not hf_urls:
        return None

    requires_token = any(_hf_url_requires_token(url) for url in hf_urls)
    if not requires_token:
        return None

    print_panel(
        "One or more pending model downloads returned HTTP 401 from Hugging Face.\n"
        "Enter a Hugging Face token once; it will be reused for all required downloads.\n"
        "Create one at: [url]https://huggingface.co/settings/tokens[/].",
        title="Hugging Face Token Required",
        style="warning",
    )
    token = prompt_text("Enter your Hugging Face token").strip()
    if not token:
        raise RuntimeError("Hugging Face token is required for one or more pending model downloads")
    return token


def _print_install_plan_preview(merged: MergedManifest, custom_nodes_dir: Path, comfyui_dir: Path, hf_token: str | None) -> None:
    print_rule("Install Plan")

    planned_nodes = Table()
    planned_nodes.add_column("Custom Node", overflow="fold")
    planned_nodes.add_column("Source", overflow="fold")
    pending_node_rows = 0
    for specs in (merged.default_custom_nodes, merged.project_custom_nodes):
        for node in specs:
            if (custom_nodes_dir / node.repo_dir).is_dir():
                continue
            planned_nodes.add_row(node.repo_dir, node.repo)
            pending_node_rows += 1
    if pending_node_rows > 0:
        console().print(planned_nodes)

    planned_files = Table()
    planned_files.add_column("File", overflow="fold")
    planned_files.add_column("Source", overflow="fold")
    planned_files.add_column("Size", justify="right")
    seen_targets: set[str] = set()
    pending_file_rows = 0
    file_rows: list[tuple[str, str, str, int | None]] = []
    known_total_bytes = 0
    unknown_size_count = 0
    for specs in (merged.default_files, merged.project_files):
        for spec in specs:
            normalized_target = Path(spec.target).as_posix()
            if normalized_target in seen_targets:
                continue
            seen_targets.add(normalized_target)
            if (comfyui_dir / normalized_target).is_file():
                continue
            remote_size = probe_remote_file_size(spec.url, hf_token=hf_token)
            size_display = format_size_for_display(remote_size) if remote_size and remote_size > 0 else "unknown"
            file_rows.append((normalized_target, spec.url, size_display, remote_size if remote_size and remote_size > 0 else None))
            if remote_size and remote_size > 0:
                known_total_bytes += remote_size
            else:
                unknown_size_count += 1
            pending_file_rows += 1
    file_rows.sort(key=lambda row: (row[3] is None, -(row[3] or 0), row[0]))
    for target, source, size_display, _size_bytes in file_rows:
        planned_files.add_row(target, source, size_display)
    if pending_file_rows > 0:
        total_display = format_size_for_display(known_total_bytes)
        if unknown_size_count > 0:
            total_display = f"{total_display} + {unknown_size_count} unknown"
        planned_files.add_row("Total", "-", total_display)
    if pending_file_rows > 0:
        console().print(planned_files)


def _print_resource_summary(
    merged: MergedManifest,
    custom_nodes_dir: Path,
    comfyui_dir: Path,
    node_failures: list[NodeInstallFailure],
    file_failures: list[FileInstallFailure],
) -> None:
    print_rule("Summary")
    node_failure_map = {failure.repo_dir: failure for failure in node_failures}
    file_failure_map = {failure.target: failure for failure in file_failures}

    def _installed_file_size_label(path: Path) -> str:
        if not path.is_file():
            return "-"
        return format_size_for_display(path.stat().st_size)

    nodes_table = Table()
    nodes_table.add_column("Custom Nodes", overflow="fold")
    nodes_table.add_column("Source", overflow="fold")
    nodes_table.add_column("Status")
    if merged.default_custom_nodes or merged.project_custom_nodes:
        for specs in (merged.default_custom_nodes, merged.project_custom_nodes):
            for node in specs:
                exists = (custom_nodes_dir / node.repo_dir).is_dir()
                failure = node_failure_map.get(node.repo_dir)
                if failure is not None:
                    status = f"[error]Failed: {failure.error}[/]"
                else:
                    status = "[success]Success[/]" if exists else "[error]Failed: missing on disk[/]"
                nodes_table.add_row(node.repo_dir, node.repo, status)
    else:
        nodes_table.add_row("(none)", "-", "-")
    console().print(nodes_table)

    files_table = Table()
    files_table.add_column("Files", overflow="fold")
    files_table.add_column("Source", overflow="fold")
    files_table.add_column("Size", justify="right")
    files_table.add_column("Status")
    if merged.default_files or merged.project_files:
        for specs in (merged.default_files, merged.project_files):
            for spec in specs:
                file_path = comfyui_dir / spec.target
                exists = file_path.is_file()
                failure = file_failure_map.get(spec.target)
                if failure is not None:
                    status = f"[error]Failed: {failure.error}[/]"
                else:
                    status = "[success]Success[/]" if exists else "[error]Failed: missing on disk[/]"
                files_table.add_row(
                    spec.target,
                    spec.url,
                    _installed_file_size_label(file_path),
                    status,
                )
    else:
        files_table.add_row("(none)", "-", "-", "-")
    console().print(files_table)
    _print_failures(node_failures, file_failures)


def _print_comfyui_link() -> None:
    runpod_url = resolve_runpod_proxy_url(8188)
    gui_url = runpod_url if runpod_url else "http://127.0.0.1:8188"
    print_success(f"ComfyUI page: [url]{gui_url}[/]")


def _execute_dependency_install(
    ctx: RuntimeContext,
    project_manifest_path: Path,
    *,
    manager_quiet: bool,
    default_manifest_path: Path | None = None,
) -> InstallExecution:
    print_rule("Dependency Install")
    network_volume = set_network_volume_default(ctx.network_volume)
    comfyui_dir, custom_nodes_dir = ensure_comfyui_workspace(network_volume)
    set_model_directories(comfyui_dir)
    require_tools(["python3", "git"])

    with status("Loading and merging manifests..."):
        merged, hf_token = _load_manifest_context(
            ctx,
            project_manifest_path,
            default_manifest_path=default_manifest_path,
        )
    hf_token = _ensure_hf_token_for_pending_downloads(merged, comfyui_dir, hf_token)
    _print_install_plan_preview(merged, custom_nodes_dir, comfyui_dir, hf_token)
    mark_running(merged, comfyui_dir)

    print_rule("ComfyUI Core")
    with status("Ensuring ComfyUI core workspace is installed..."):
        ensure_comfy_cli_ready(network_volume)
        verify_comfyui_core_workspace(comfyui_dir)
        enable_manager_gui(comfyui_dir, quiet=manager_quiet)

    print_rule("Custom Nodes")
    node_failures = install_custom_nodes(
        merged.merged_custom_nodes, custom_nodes_dir, on_progress=lambda: mark_running(merged, comfyui_dir)
    )

    print_rule("Files")
    file_failures = install_files(
        merged.merged_files, comfyui_dir, hf_token=hf_token, on_progress=lambda: mark_running(merged, comfyui_dir)
    )
    file_failures = _retry_hf_401_file_downloads(
        merged,
        comfyui_dir,
        file_failures,
        on_progress=lambda: mark_running(merged, comfyui_dir),
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
        print_info(line)


def run_dependency_install_flow(
    ctx: RuntimeContext,
    project_manifest_path: Path,
    *,
    default_manifest_path: Path | None = None,
    show_completion: bool = True,
    show_comfyui_link: bool = True,
) -> None:
    ctx.install_start_ts = now_epoch()
    execution = _execute_dependency_install(
        ctx,
        project_manifest_path,
        manager_quiet=True,
        default_manifest_path=default_manifest_path,
    )

    mark_done(execution.merged, execution.comfyui_dir)
    _print_resource_summary(
        execution.merged,
        execution.custom_nodes_dir,
        execution.comfyui_dir,
        execution.node_failures,
        execution.file_failures,
    )
    if show_completion:
        print_success("Dependency installation complete.")
    if show_comfyui_link:
        _print_comfyui_link()


def cmd_install(ctx: RuntimeContext) -> None:
    configure_process_env()
    network_volume = prepare_network_volume_and_start_jupyter(ctx.network_volume)
    network_volume = set_network_volume_default(network_volume)
    write_runtime_instructions(network_volume)

    comfyui_dir, _custom_nodes_dir = ensure_comfyui_workspace(network_volume)
    maybe_enable_nodes_setting(network_volume)

    mark_idle(None, comfyui_dir)
    start_setup_page_server(ctx.setup_page_html_path)

    print_success("Jupyter is running.")
    if verify_install_sentinel(network_volume):
        print_info("Install marker found. Starting ComfyUI...")
        try:
            ensure_comfy_cli_ready(network_volume)
            startup_lines = start_comfyui_service(comfyui_dir, network_volume)
            for line in startup_lines:
                print_info(line)
        except Exception as exc:
            print_warning(f"Failed to auto-start ComfyUI. Run 'dynamic-comfyui start' from the Jupyter terminal. ({exc})")

    while True:
        import time

        time.sleep(3600)


def _save_selected_project(network_volume: Path, manifest_path: Path, source_url: str) -> None:
    save_project_state(network_volume, "active-project", manifest_path, source_url)
    print_success("Selected project: active-project")


def cmd_start(ctx: RuntimeContext, project_url: str | None = None) -> None:
    configure_process_env()
    network_volume = set_network_volume_default(ctx.network_volume)
    if project_url is not None:
        manifest_path, source_url = prepare_project_manifest(network_volume, project_url)
    else:
        manifest_path, source_url = prompt_and_prepare_project_manifest(network_volume)
    _save_selected_project(network_volume, manifest_path, source_url)
    try:
        run_comfyui_install_flow(ctx, manifest_path)
    except Exception as exc:
        comfyui_dir, _ = ensure_comfyui_workspace(network_volume)
        mark_failed(None, comfyui_dir, f"Installation failed. {exc}")
        raise


def cmd_install_deps(ctx: RuntimeContext, project_urls: list[str] | None = None) -> None:
    configure_process_env()
    network_volume = set_network_volume_default(ctx.network_volume)
    detected_comfyui = discover_comfyui_workspace(network_volume)
    if detected_comfyui is not None:
        detected_volume = detected_comfyui.parent
        if detected_volume != network_volume:
            print_info(f"Detected ComfyUI workspace at {detected_comfyui}. Using {detected_volume} as workspace root.")
        network_volume = detected_volume
    else:
        print_warning(f"Could not auto-detect ComfyUI workspace. Using configured workspace root: {network_volume}")

    if not project_urls:
        manifest_path, source_url = prompt_and_prepare_project_manifest(network_volume)
        _save_selected_project(network_volume, manifest_path, source_url)
        ctx.network_volume = network_volume
        try:
            run_dependency_install_flow(ctx, manifest_path)
        except Exception as exc:
            comfyui_dir, _ = ensure_comfyui_workspace(network_volume)
            mark_failed(None, comfyui_dir, f"Dependency installation failed. {exc}")
            raise
        return

    total = len(project_urls)
    ctx.network_volume = network_volume
    shared_manifest_temp_dir = Path(tempfile.mkdtemp(prefix="dynamic-comfyui-install-default-manifest-"))
    shared_default_manifest_path = resolve_default_manifest(ctx.package_json_path, shared_manifest_temp_dir)
    for index, project_url in enumerate(project_urls, start=1):
        manifest_path, source_url = prepare_project_manifest(network_volume, project_url)
        print_info(f"Installing dependencies for project [{index}/{total}]: [url]{source_url}[/]")
        _save_selected_project(network_volume, manifest_path, source_url)
        try:
            run_dependency_install_flow(
                ctx,
                manifest_path,
                default_manifest_path=shared_default_manifest_path,
                show_completion=False,
                show_comfyui_link=False,
            )
        except Exception as exc:
            comfyui_dir, _ = ensure_comfyui_workspace(network_volume)
            mark_failed(None, comfyui_dir, f"Dependency installation failed. {exc}")
            raise
    print_success("Dependency installation complete.")
    _print_comfyui_link()


def cmd_remove_deps(ctx: RuntimeContext, project_urls: list[str] | None = None) -> None:
    configure_process_env()
    network_volume = set_network_volume_default(ctx.network_volume)
    detected_comfyui = discover_comfyui_workspace(network_volume)
    if detected_comfyui is not None:
        detected_volume = detected_comfyui.parent
        if detected_volume != network_volume:
            print_info(f"Detected ComfyUI workspace at {detected_comfyui}. Using {detected_volume} as workspace root.")
        network_volume = detected_volume
    else:
        print_warning(f"Could not auto-detect ComfyUI workspace. Using configured workspace root: {network_volume}")

    comfyui_dir, _custom_nodes_dir = ensure_comfyui_workspace(network_volume)

    if not project_urls:
        source_url = _prompt_manifest_url()
        if not source_url:
            raise RuntimeError("Project URL is required for remove-deps")
        project_urls = [source_url]

    total = len(project_urls)
    for index, source_url in enumerate(project_urls, start=1):
        normalized = normalize_manifest_url(source_url.strip())
        validate_manifest_url(normalized)
        manifest_path = Path(tempfile.mkstemp(prefix="dynamic-comfyui-remove-deps.", suffix=".json")[1])
        download_manifest(normalized, manifest_path)
        _node_dirs, file_targets = resources_for_cleanup(manifest_path)
        print_info(f"Removing files for project [{index}/{total}]: [url]{normalized}[/]")
        for target in file_targets:
            file_path = comfyui_dir / target
            if file_path.is_file():
                print_info(f"Removing file: {target}")
                file_path.unlink()

    print_success("File removal complete.")


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
        print_info(f"Previous project: {previous_key or 'active-project'}")
        print_info("Selected project: active-project")
        while True:
            if prompt_confirm("Remove resources from previous project?", default=False):
                cleanup_previous = True
                break
            break

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
    detected_comfyui = discover_comfyui_workspace(network_volume)
    if detected_comfyui is not None:
        detected_volume = detected_comfyui.parent
        if detected_volume != network_volume:
            print_info(f"Detected ComfyUI workspace at {detected_comfyui}. Using {detected_volume} as workspace root.")
        network_volume = detected_volume
    else:
        print_warning(f"Could not auto-detect ComfyUI workspace. Using configured workspace root: {network_volume}")

    key, _saved_manifest_path, source_url = load_project_state(network_volume)
    manifest_path = active_project_manifest_path(network_volume)

    if source_url:
        source_url = normalize_manifest_url(source_url)
        validate_manifest_url(source_url)
        download_manifest(source_url, manifest_path)
    else:
        write_empty_manifest(manifest_path)

    save_project_state(network_volume, key, manifest_path, source_url)
    ctx.network_volume = network_volume
    run_comfyui_install_flow(ctx, manifest_path)


def cmd_restart(ctx: RuntimeContext) -> None:
    configure_process_env()
    network_volume = set_network_volume_default(ctx.network_volume)
    detected_comfyui = discover_comfyui_workspace(network_volume)
    if detected_comfyui is not None:
        detected_volume = detected_comfyui.parent
        if detected_volume != network_volume:
            print_info(f"Detected ComfyUI workspace at {detected_comfyui}. Using {detected_volume} as workspace root.")
        network_volume = detected_volume
        comfyui_dir = detected_comfyui
    else:
        print_warning(f"Could not auto-detect ComfyUI workspace. Using configured workspace root: {network_volume}")
        comfyui_dir, _ = ensure_comfyui_workspace(network_volume)

    print_rule("Restart ComfyUI")
    startup_lines = start_comfyui_service_for_restart(comfyui_dir, network_volume)
    for line in startup_lines:
        print_info(line)
    print_success("ComfyUI restart complete.")


def cmd_stop(ctx: RuntimeContext) -> None:
    configure_process_env()
    network_volume = set_network_volume_default(ctx.network_volume)
    detected_comfyui = discover_comfyui_workspace(network_volume)
    if detected_comfyui is not None:
        detected_volume = detected_comfyui.parent
        if detected_volume != network_volume:
            print_info(f"Detected ComfyUI workspace at {detected_comfyui}. Using {detected_volume} as workspace root.")
        network_volume = detected_volume
        comfyui_dir = detected_comfyui
    else:
        print_warning(f"Could not auto-detect ComfyUI workspace. Using configured workspace root: {network_volume}")
        comfyui_dir, _ = ensure_comfyui_workspace(network_volume)

    print_rule("Stop ComfyUI")
    stop_comfyui_service(comfyui_dir)
    print_success("ComfyUI stop complete.")


def cmd_update_dc(_ctx: RuntimeContext) -> None:
    if not upgrade_runtime_package():
        raise RuntimeError("Runtime package update failed")


def cmd_uninstall_dc(_ctx: RuntimeContext) -> None:
    if not uninstall_runtime_package():
        raise RuntimeError("Runtime package uninstall failed")


def cmd_system_info(ctx: RuntimeContext) -> None:
    configure_process_env()
    network_volume = set_network_volume_default(ctx.network_volume)
    detected_comfyui = discover_comfyui_workspace(network_volume)
    info = collect_system_info(detected_comfyui)
    print_system_info(info)
