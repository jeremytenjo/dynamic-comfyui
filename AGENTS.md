# AGENTS Rules

- Keep startup logic modular: reusable startup behaviors must be implemented in dedicated Python modules under `src/dynamic_comfyui_runtime/runtime/` and invoked from the CLI entrypoint.
- Do not add configuration knobs, feature flags, or optional toggles unless the user explicitly asks for them.
