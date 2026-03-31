# shellcheck shell=bash

preloaded_comfyui_path_file() {
    echo "/opt/comfyui-preload.path"
}


append_candidate_dir_if_set() {
    local candidate="$1"
    local -n candidate_list_ref="$2"

    if [ -n "$candidate" ]; then
        candidate_list_ref+=("$candidate")
    fi
}


resolve_preloaded_comfyui_dir_with_comfy_which() {
    if ! command -v comfy > /dev/null 2>&1; then
        return 1
    fi

    local probe_workspace="/opt/comfyui-preload"
    local resolved
    resolved="$(comfy --workspace="$probe_workspace" which 2>/dev/null | tail -n 1 | tr -d '\r' || true)"
    if [ -n "$resolved" ]; then
        printf '%s\n' "$resolved"
        return 0
    fi

    return 1
}


preloaded_comfyui_dir() {
    local path_file
    path_file="$(preloaded_comfyui_path_file)"

    local -a candidates=()
    if [ -f "$path_file" ]; then
        local from_file
        from_file="$(head -n 1 "$path_file" | tr -d '\r' || true)"
        append_candidate_dir_if_set "$from_file" candidates
    fi

    local from_which
    from_which="$(resolve_preloaded_comfyui_dir_with_comfy_which || true)"
    append_candidate_dir_if_set "$from_which" candidates

    append_candidate_dir_if_set "/opt/comfyui-preload" candidates
    append_candidate_dir_if_set "/opt/comfyui-preload/ComfyUI" candidates

    local candidate
    for candidate in "${candidates[@]}"; do
        if is_comfyui_workspace_sane "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}


is_comfyui_workspace_sane() {
    local workspace_dir="$1"

    [ -d "$workspace_dir/.git" ] &&
        [ -f "$workspace_dir/main.py" ] &&
        [ -d "$workspace_dir/custom_nodes" ] &&
        [ -d "$workspace_dir/models" ]
}


install_comfy_cli_package() {
    local -a pip_args=(install comfy-cli)
    local pip_cache_dir=""

    if [ -n "$NETWORK_VOLUME" ] && [ "$NETWORK_VOLUME" != "/" ] && [ -d "$NETWORK_VOLUME" ] && [ -w "$NETWORK_VOLUME" ]; then
        pip_cache_dir="$NETWORK_VOLUME/.cache/pip"
        if mkdir -p "$pip_cache_dir"; then
            echo "Using persistent pip cache: $pip_cache_dir"
            pip_args=(install --cache-dir "$pip_cache_dir" comfy-cli)
        else
            echo "⚠️ Could not create persistent pip cache dir, falling back to no cache."
            pip_args=(install --no-cache-dir comfy-cli)
        fi
    else
        echo "Using no pip cache (no writable persistent network volume detected)."
        pip_args=(install --no-cache-dir comfy-cli)
    fi

    python3 -m pip "${pip_args[@]}"
}


comfy_global_noninteractive_args() {
    local help_text
    help_text="$(comfy --help 2>/dev/null || true)"

    if printf '%s' "$help_text" | grep -q -- '--skip-prompt'; then
        printf '%s\n' "--skip-prompt"
    fi
    if printf '%s' "$help_text" | grep -q -- '--no-enable-telemetry'; then
        printf '%s\n' "--no-enable-telemetry"
    fi
}


ensure_comfy_cli_ready() {
    if ! command -v comfy > /dev/null 2>&1; then
        echo "Installing comfy-cli..."
        if ! install_comfy_cli_package; then
            echo "❌ Failed to install comfy-cli."
            return 1
        fi
    fi

    if ! command -v comfy > /dev/null 2>&1; then
        echo "❌ comfy-cli installation completed but 'comfy' command is not available."
        return 1
    fi

    # Keep automation non-interactive by disabling telemetry prompt.
    local -a comfy_disable_tracking_cmd=(comfy)
    while IFS= read -r arg; do
        [ -n "$arg" ] && comfy_disable_tracking_cmd+=("$arg")
    done < <(comfy_global_noninteractive_args)
    comfy_disable_tracking_cmd+=(tracking disable)
    "${comfy_disable_tracking_cmd[@]}" > /dev/null 2>&1 || true

    return 0
}


prepare_comfyui_install_target() {
    if [ -d "$COMFYUI_DIR/.git" ]; then
        return 0
    fi

    if [ ! -d "$COMFYUI_DIR" ]; then
        return 0
    fi

    local backup_dir="$NETWORK_VOLUME/ComfyUI.invalid.$(date +%Y%m%d%H%M%S)"
    echo "⚠️ Found non-git ComfyUI directory at $COMFYUI_DIR"
    echo "Moving it to $backup_dir so comfy-cli can install cleanly."
    if ! mv "$COMFYUI_DIR" "$backup_dir"; then
        echo "❌ Failed to move invalid ComfyUI directory: $COMFYUI_DIR"
        return 1
    fi
    COMFYUI_INVALID_BACKUP_DIR="$backup_dir"
    export COMFYUI_INVALID_BACKUP_DIR

    return 0
}


cleanup_comfyui_invalid_backup() {
    if [ -z "$COMFYUI_INVALID_BACKUP_DIR" ]; then
        return 0
    fi

    if [ ! -d "$COMFYUI_INVALID_BACKUP_DIR" ]; then
        return 0
    fi

    echo "Removing temporary invalid ComfyUI backup: $COMFYUI_INVALID_BACKUP_DIR"
    if ! rm -rf "$COMFYUI_INVALID_BACKUP_DIR"; then
        echo "⚠️ Failed to remove temporary backup: $COMFYUI_INVALID_BACKUP_DIR"
        return 1
    fi

    COMFYUI_INVALID_BACKUP_DIR=""
    export COMFYUI_INVALID_BACKUP_DIR

    return 0
}


seed_comfyui_workspace_from_preload() {
    local preload_dir
    preload_dir="$(preloaded_comfyui_dir || true)"

    if [ -d "$COMFYUI_DIR/.git" ]; then
        # Existing workspace should continue through comfy-cli install/update path.
        return 1
    fi

    if [ -e "$COMFYUI_DIR" ]; then
        # A non-git directory would have been handled by prepare_comfyui_install_target.
        return 1
    fi

    if [ -z "$preload_dir" ] || [ ! -d "$preload_dir" ]; then
        return 1
    fi

    if ! is_comfyui_workspace_sane "$preload_dir"; then
        echo "⚠️ Preloaded ComfyUI workspace is invalid: $preload_dir"
        return 1
    fi

    echo "Seeding ComfyUI workspace from preloaded core: $preload_dir"
    if ! cp -a "$preload_dir" "$COMFYUI_DIR"; then
        echo "⚠️ Failed to seed ComfyUI workspace from preload; falling back to comfy install."
        rm -rf "$COMFYUI_DIR" 2>/dev/null || true
        return 1
    fi

    if ! is_comfyui_workspace_sane "$COMFYUI_DIR"; then
        echo "⚠️ Seeded ComfyUI workspace failed validation; falling back to comfy install."
        rm -rf "$COMFYUI_DIR" 2>/dev/null || true
        return 1
    fi

    echo "✅ Seeded ComfyUI workspace from preloaded core."
    return 0
}


install_comfyui_with_comfy_cli() {
    if ! ensure_comfy_cli_ready; then
        return 1
    fi

    if ! prepare_comfyui_install_target; then
        return 1
    fi

    if seed_comfyui_workspace_from_preload; then
        return 0
    fi

    local install_help
    install_help="$(comfy install --help 2>/dev/null || true)"
    local -a comfy_install_cmd=(comfy)
    while IFS= read -r arg; do
        [ -n "$arg" ] && comfy_install_cmd+=("$arg")
    done < <(comfy_global_noninteractive_args)
    comfy_install_cmd+=(--workspace="$COMFYUI_DIR" install)
    if printf '%s' "$install_help" | grep -q -- '--nvidia'; then
        comfy_install_cmd+=(--nvidia)
    fi

    echo "Installing/updating ComfyUI workspace via comfy-cli..."
    if ! "${comfy_install_cmd[@]}"; then
        echo "❌ comfy-cli failed to install/update ComfyUI at $COMFYUI_DIR"
        return 1
    fi

    return 0
}
