# AGENTS Rules

- Keep startup logic modular: reusable startup behaviors must be implemented in dedicated Python modules under `src/dynamic_comfyui_runtime/runtime/` and invoked from the CLI entrypoint.
- Do not add configuration knobs, feature flags, or optional toggles unless the user explicitly asks for them.
- Use `print_info` (and shared `runtime.ui` print helpers) for user-facing runtime output instead of raw `print(...)`, including link lines.
