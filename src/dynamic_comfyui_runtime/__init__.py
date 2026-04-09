"""dynamic-comfyui runtime helpers."""

__all__ = ["runtime_root"]


def runtime_root() -> str:
    """Return the installed runtime package root directory."""
    from pathlib import Path

    return str(Path(__file__).resolve().parent)
