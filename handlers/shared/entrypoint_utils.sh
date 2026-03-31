# shellcheck shell=bash


enable_tcmalloc_preload() {
    local tcmalloc
    tcmalloc="$(ldconfig -p | grep -Po 'libtcmalloc.so.\d' | head -n 1 || true)"
    if [ -n "$tcmalloc" ]; then
        export LD_PRELOAD="$tcmalloc"
    fi
}


source_handler_glob() {
    local glob_pattern="$1"
    local handler_file
    for handler_file in $glob_pattern; do
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
