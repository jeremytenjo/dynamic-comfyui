# shellcheck shell=bash


enable_tcmalloc_preload() {
    local tcmalloc
    tcmalloc="$(ldconfig -p | grep -Po 'libtcmalloc.so.\d' | head -n 1 || true)"
    if [ -n "$tcmalloc" ]; then
        export LD_PRELOAD="$tcmalloc"
    fi
}


source_handler_glob() {
    local handler_file
    for handler_file in "$@"; do
        if [ -f "$handler_file" ]; then
            # shellcheck source=/dev/null
            source "$handler_file"
        fi
    done
}


source_install_handlers() {
    local script_dir="$1"
    source_handler_glob "$script_dir"/handlers/install/*.sh
}


source_start_handlers() {
    local script_dir="$1"
    source_handler_glob "$script_dir"/handlers/start/*.sh
}


read_nonempty_lines() {
    local input_file="$1"

    if [ ! -f "$input_file" ]; then
        return 1
    fi

    READ_NONEMPTY_LINES=()
    READ_NONEMPTY_LINES_COUNT=0

    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        READ_NONEMPTY_LINES+=("$line")
        READ_NONEMPTY_LINES_COUNT=$((READ_NONEMPTY_LINES_COUNT + 1))
    done < "$input_file"

    return 0
}


curl_download_to_file() {
    local source_url="$1"
    local target_path="$2"
    local -a curl_args=()

    mkdir -p "$(dirname "$target_path")"
    curl_args=(--silent --show-error --fail --location)

    if [[ "$source_url" =~ ^https?://(www\.)?huggingface\.co/ ]]; then
        if [ "${REQUIRE_HUGGINGFACE_TOKEN:-0}" = "1" ]; then
            if [ -z "${HF_TOKEN:-}" ]; then
                echo "❌ Hugging Face token is required but not set for URL: $source_url"
                return 1
            fi
            curl_args+=(--header "Authorization: Bearer ${HF_TOKEN}")
        fi
    fi

    if ! curl "${curl_args[@]}" "$source_url" --output "$target_path"; then
        return 1
    fi

    return 0
}


is_http_reachable() {
    local url="$1"
    local connect_timeout="${2:-2}"
    local max_time="${3:-5}"

    if curl --silent --fail --connect-timeout "$connect_timeout" --max-time "$max_time" "$url" --output /dev/null; then
        return 0
    fi
    return 1
}
