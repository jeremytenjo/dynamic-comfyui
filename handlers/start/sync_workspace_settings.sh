# shellcheck shell=bash


sync_workspace_settings_file() {
    local source_settings="/settings.yaml"
    local target_settings="$NETWORK_VOLUME/settings.yaml"

    if [ ! -f "$source_settings" ]; then
        echo "❌ Missing required settings source file: $source_settings" >&2
        echo "❌ Add settings.yaml at repo root so it is included in the image." >&2
        return 1
    fi

    if [ ! -r "$source_settings" ]; then
        echo "❌ Cannot read required settings source file: $source_settings" >&2
        return 1
    fi

    if ! mkdir -p "$NETWORK_VOLUME"; then
        echo "❌ Failed to create network volume directory: $NETWORK_VOLUME" >&2
        return 1
    fi

    if ! cp -f "$source_settings" "$target_settings"; then
        echo "❌ Failed to sync settings file to: $target_settings" >&2
        return 1
    fi

    echo "Synced settings file to $target_settings"
    return 0
}
