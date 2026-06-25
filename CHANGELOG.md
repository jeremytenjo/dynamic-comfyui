# Changelog

All notable changes to this project will be documented in this file.

## 2026-05-25

### Added
- Added manifest hook support for `hooks.on_install_complete.commands` (list of non-empty shell command strings).
- Added end-of-batch confirmation in multi-URL `dc install-deps` runs to optionally execute collected `on_install_complete` commands after all installs complete successfully.
- Added per-file download duration logging and next-file download duration estimates based on the most recently completed download rate.

### Changed
- Multi-URL `dc install-deps` now performs hook preflight validation and fails fast if two or more selected manifests define the same overriding hook (`on_install_complete`), preventing ambiguous overrides.
