from __future__ import annotations

import os
import urllib.error
import urllib.parse
import urllib.request


def is_huggingface_url(url: str) -> bool:
    return "huggingface.co" in urllib.parse.urlparse(url).netloc.lower()


def read_hf_token_from_env() -> str | None:
    for name in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACE_TOKEN"):
        value = os.environ.get(name, "").strip()
        if value:
            return value
    return None


def hf_url_requires_token(url: str) -> bool:
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
