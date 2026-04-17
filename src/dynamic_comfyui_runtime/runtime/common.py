from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Iterable


def run(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
    quiet: bool = False,
    timeout: int | None = None,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    kwargs: dict[str, object] = {"cwd": str(cwd) if cwd else None, "text": True}
    if quiet:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
    if input_text is not None:
        kwargs["input"] = input_text
    try:
        completed = subprocess.run(cmd, timeout=timeout, **kwargs)  # noqa: S603
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"Command timed out after {timeout}s: {' '.join(cmd)}") from exc
    if check and completed.returncode != 0:
        raise RuntimeError(f"Command failed ({completed.returncode}): {' '.join(cmd)}")
    return completed


def command_exists(name: str) -> bool:
    return shutil.which(name) is not None


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def find_file_upwards(filename: str, start_dir: Path | None = None) -> Path | None:
    current = (start_dir or Path.cwd()).resolve()
    for directory in (current, *current.parents):
        candidate = directory / filename
        if candidate.is_file():
            return candidate
    return None


def read_json(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise ValueError(f"JSON root must be object: {path}")
    return data


def write_json(path: Path, payload: dict) -> None:
    ensure_dir(path.parent)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def normalize_github_blob_url(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    if parsed.netloc != "github.com":
        return url
    parts = [p for p in parsed.path.split("/") if p]
    if len(parts) >= 5 and parts[2] == "blob":
        owner, repo, _blob, ref = parts[:4]
        subpath = "/".join(parts[4:])
        return f"https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{subpath}"
    return url


def is_http_reachable(url: str, timeout: int = 5) -> bool:
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            return 200 <= int(resp.status) < 400
    except Exception:
        return False


def download_file(
    url: str,
    target: Path,
    *,
    hf_token: str | None = None,
    on_progress: callable | None = None,
) -> None:
    ensure_dir(target.parent)
    parsed = urllib.parse.urlparse(url)
    host = parsed.netloc.lower()
    headers = {
        "Accept": "*/*",
        "User-Agent": "dynamic-comfyui-runtime-downloader/1.0",
    }
    if "huggingface.co" in host and hf_token:
        headers["Authorization"] = f"Bearer {hf_token}"
    if "civitai.com" in host:
        headers["Referer"] = "https://civitai.com/"
        headers["Origin"] = "https://civitai.com"
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:  # noqa: S310
            total_header = resp.headers.get("Content-Length")
            total_size: int | None = None
            if total_header:
                try:
                    parsed_size = int(total_header)
                    total_size = parsed_size if parsed_size > 0 else None
                except Exception:
                    total_size = None

            downloaded = 0
            chunk_size = 1024 * 1024
            with target.open("wb") as out_file:
                while True:
                    chunk = resp.read(chunk_size)
                    if not chunk:
                        break
                    out_file.write(chunk)
                    downloaded += len(chunk)
                    if on_progress:
                        on_progress(downloaded, total_size)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Download failed ({exc.code}) for {url}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Download failed for {url}: {exc.reason}") from exc


def probe_remote_file_size(url: str, *, hf_token: str | None = None) -> int | None:
    parsed = urllib.parse.urlparse(url)
    host = parsed.netloc.lower()
    headers = {
        "Accept": "*/*",
        "User-Agent": "dynamic-comfyui-runtime-downloader/1.0",
    }
    if "huggingface.co" in host and hf_token:
        headers["Authorization"] = f"Bearer {hf_token}"
    if "civitai.com" in host:
        headers["Referer"] = "https://civitai.com/"
        headers["Origin"] = "https://civitai.com"

    def _parse_positive_int(raw: str | None) -> int | None:
        if not raw:
            return None
        try:
            parsed_value = int(raw)
        except Exception:
            return None
        return parsed_value if parsed_value > 0 else None

    try:
        head_req = urllib.request.Request(url, headers=headers, method="HEAD")
        with urllib.request.urlopen(head_req, timeout=30) as resp:  # noqa: S310
            size = _parse_positive_int(resp.headers.get("Content-Length"))
            if size is not None:
                return size
    except Exception:
        pass

    try:
        range_headers = dict(headers)
        range_headers["Range"] = "bytes=0-0"
        get_req = urllib.request.Request(url, headers=range_headers, method="GET")
        with urllib.request.urlopen(get_req, timeout=30) as resp:  # noqa: S310
            content_range = resp.headers.get("Content-Range", "")
            if "/" in content_range:
                suffix = content_range.rsplit("/", 1)[-1].strip()
                size = _parse_positive_int(suffix)
                if size is not None:
                    return size
            size = _parse_positive_int(resp.headers.get("Content-Length"))
            if size is not None:
                return size
    except Exception:
        return None

    return None


def read_nonempty_lines(path: Path) -> list[str]:
    if not path.is_file():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def format_size_for_display(byte_count: int) -> str:
    if byte_count < 0:
        return "N/A"
    mb = byte_count / (1024 * 1024)
    if mb >= 1000:
        return f"{byte_count / (1024 * 1024 * 1024):.2f} GB"
    return f"{mb:.1f} MB"


def now_epoch() -> int:
    return int(time.time())


def utc_timestamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def require_tools(tools: Iterable[str]) -> None:
    missing = [tool for tool in tools if not command_exists(tool)]
    if missing:
        raise RuntimeError(f"Missing required tools: {', '.join(missing)}")


def sanitize_torch_cuda_alloc_conf() -> None:
    raw_conf = os.environ.get("PYTORCH_CUDA_ALLOC_CONF", "")
    if not raw_conf:
        os.environ.pop("PYTORCH_CUDA_ALLOC_CONF", None)
        return
    sanitized: list[str] = []
    for token in raw_conf.split(","):
        token = token.strip()
        if not token or token.startswith("backend:"):
            continue
        sanitized.append(token)
    if sanitized:
        os.environ["PYTORCH_CUDA_ALLOC_CONF"] = ",".join(sanitized)
    else:
        os.environ.pop("PYTORCH_CUDA_ALLOC_CONF", None)


def configure_tcmalloc_preload() -> None:
    if not command_exists("ldconfig"):
        return
    out = run(["ldconfig", "-p"], check=False, quiet=True)
    if out.returncode != 0:
        return
    for line in (out.stdout or "").splitlines():
        if "libtcmalloc.so." in line:
            token = line.strip().split()[-1]
            if token:
                os.environ["LD_PRELOAD"] = token
                return
