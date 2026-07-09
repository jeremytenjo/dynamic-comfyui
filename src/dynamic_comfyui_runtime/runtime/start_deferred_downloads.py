from __future__ import annotations

import threading
from dataclasses import replace
from pathlib import Path

from .installer import install_files
from .manifests import FileSpec, MergedManifest
from .ui import print_error, print_info, print_success


def split_start_deferred_files(merged: MergedManifest) -> tuple[MergedManifest, list[FileSpec]]:
    deferred_files = [spec for spec in merged.merged_files if spec.start_comfyui_before_downloading]
    if not deferred_files:
        return merged, []

    deferred_targets = {Path(spec.target).as_posix() for spec in deferred_files}

    def _keep_initial_files(files: list[FileSpec]) -> list[FileSpec]:
        return [spec for spec in files if Path(spec.target).as_posix() not in deferred_targets]

    initial_manifest = replace(
        merged,
        merged_files=_keep_initial_files(merged.merged_files),
        default_files=_keep_initial_files(merged.default_files),
        project_files=_keep_initial_files(merged.project_files),
    )
    return initial_manifest, deferred_files


def start_background_deferred_file_downloads(
    files: list[FileSpec],
    comfyui_dir: Path,
    *,
    hf_token: str | None,
    on_progress: callable | None = None,
) -> threading.Thread | None:
    if not files:
        return None

    def _run() -> None:
        print_info(f"Starting {len(files)} deferred file download(s) after ComfyUI launch.")
        failures = install_files(files, comfyui_dir, hf_token=hf_token, on_progress=on_progress)
        if failures:
            print_error("Deferred file downloads completed with failures:")
            for failure in failures:
                print_error(f" - {failure.target} ({failure.error})")
            return
        print_success("Deferred file downloads complete.")

    thread = threading.Thread(
        target=_run,
        name="dynamic-comfyui-deferred-file-downloads",
        daemon=True,
    )
    thread.start()
    return thread
