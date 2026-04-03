# shellcheck shell=bash


print_installed_resources_summary() {
    echo "Installed resource summary (final):"
    print_installed_custom_nodes_summary
    print_installed_models_summary
    print_installed_files_summary
}
