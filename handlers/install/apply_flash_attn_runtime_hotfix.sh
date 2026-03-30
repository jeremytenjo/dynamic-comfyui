# shellcheck shell=bash


apply_flash_attn_runtime_hotfix() {
    # Runtime hotfix for transformers optional dependency probing.
    # Some custom nodes hit KeyError('flash_attn') during import.
    local hotfix_dir="/tmp/comfy_python_hotfixes"
    mkdir -p "$hotfix_dir"

    cat > "$hotfix_dir/sitecustomize.py" <<'PY'
try:
    from transformers.utils import import_utils as _iu  # type: ignore
    _flash_keys = {"flash_attn", "flash-attn"}

    for _name in (
        "PACKAGE_DISTRIBUTION_MAPPING",
        "PACKAGES_DISTRIBUTION_MAPPING",
        "PACKAGE_TO_DISTRIBUTION",
        "_PACKAGE_DISTRIBUTION_MAPPING",
    ):
        _mapping = getattr(_iu, _name, None)
        if isinstance(_mapping, dict):
            _mapping.setdefault("flash_attn", "flash-attn")
            _mapping.setdefault("flash-attn", "flash-attn")

    for _fn_name in ("_is_package_available", "is_package_available", "get_package_version"):
        _orig = getattr(_iu, _fn_name, None)
        if callable(_orig):
            def _wrap(orig):
                def _inner(*args, **kwargs):
                    try:
                        return orig(*args, **kwargs)
                    except KeyError as e:
                        _pkg = args[0] if args else kwargs.get("pkg", kwargs.get("package_name"))
                        if _pkg in _flash_keys and str(e).strip("'\"") in _flash_keys:
                            if kwargs.get("return_version"):
                                return False, "N/A"
                            return False
                        raise
                return _inner
            setattr(_iu, _fn_name, _wrap(_orig))
except Exception:
    pass
PY

    if [ -n "${PYTHONPATH:-}" ]; then
        export PYTHONPATH="$hotfix_dir:$PYTHONPATH"
    else
        export PYTHONPATH="$hotfix_dir"
    fi
}
