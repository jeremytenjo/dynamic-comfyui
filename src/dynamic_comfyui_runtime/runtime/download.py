from __future__ import annotations

import time
import urllib.parse
from pathlib import Path

from .common import download_file, format_size_for_display, probe_remote_file_size
from .huggingface import hf_url_requires_token, is_huggingface_url, read_hf_token_from_env
from .ui import print_info, print_panel, print_success, prompt_text


def filename_from_url(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("Download URL must be an http(s) URL")
    name = Path(urllib.parse.unquote(parsed.path)).name
    if not name:
        raise ValueError("Download URL path must include a filename")
    return name


def _format_duration(seconds: float) -> str:
    seconds = max(0, int(round(seconds)))
    if seconds < 60:
        return f"{seconds}s"
    minutes, seconds = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m {seconds}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes}m {seconds}s"


def _prompt_hf_token(message: str) -> str:
    print_panel(
        f"{message}\n"
        "Enter a Hugging Face token to download this file.\n"
        "Create one at: [url]https://huggingface.co/settings/tokens[/].",
        title="Hugging Face Token Required",
        style="warning",
    )
    token = prompt_text("Enter your Hugging Face token", password=True).strip()
    if not token:
        raise RuntimeError("Hugging Face token is required for this download")
    return token


def download_url_to_current_directory(url: str) -> Path:
    target = Path.cwd() / filename_from_url(url)
    hf_token = read_hf_token_from_env()

    if is_huggingface_url(url) and not hf_token and hf_url_requires_token(url):
        hf_token = _prompt_hf_token("This Hugging Face download returned HTTP 401.")

    return _download_with_optional_hf_retry(url, target, hf_token=hf_token)


def _download_with_optional_hf_retry(url: str, target: Path, *, hf_token: str | None) -> Path:
    try:
        _download_once(url, target, hf_token=hf_token)
        return target
    except RuntimeError as exc:
        if not is_huggingface_url(url) or "401" not in str(exc):
            raise
        retry_token = _prompt_hf_token("This Hugging Face download returned HTTP 401.")
        _download_once(url, target, hf_token=retry_token)
        return target


def _download_once(url: str, target: Path, *, hf_token: str | None) -> None:
    total_size = probe_remote_file_size(url, hf_token=hf_token)
    if total_size and total_size > 0:
        print_info(f"Downloading [url]{url}[/] to {target} ({format_size_for_display(total_size)})")
    else:
        print_info(f"Downloading [url]{url}[/] to {target} (size unknown)")

    start_time = time.monotonic()
    last_log_time = 0.0
    last_checkpoint = 0

    def _on_progress(downloaded: int, reported_total: int | None) -> None:
        nonlocal last_log_time, last_checkpoint
        now = time.monotonic()
        total = total_size if total_size and total_size > 0 else reported_total
        if not total or total <= 0:
            if downloaded > 0 and now - last_log_time >= 5.0:
                print_info(f"[download] {target.name}: {format_size_for_display(downloaded)} downloaded")
                last_log_time = now
            return

        percent = int((downloaded * 100) / total)
        next_checkpoint = min((percent // 5) * 5, 95)
        if next_checkpoint > last_checkpoint:
            print_info(
                f"[download] {target.name}: {next_checkpoint}% "
                f"({format_size_for_display(downloaded)}/{format_size_for_display(total)})"
            )
            last_checkpoint = next_checkpoint
            last_log_time = now
        if downloaded > 0 and now - last_log_time >= 20.0:
            print_info(
                f"[download] {target.name}: {percent}% "
                f"({format_size_for_display(downloaded)}/{format_size_for_display(total)})"
            )
            last_log_time = now

    download_file(url, target, hf_token=hf_token, on_progress=_on_progress, backend="urllib")
    elapsed = time.monotonic() - start_time
    downloaded = target.stat().st_size if target.is_file() else 0
    print_success(f"Downloaded {target} ({format_size_for_display(downloaded)}) in {_format_duration(elapsed)}.")
