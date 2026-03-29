# AGENTS Rules

- Keep startup logic modular: reusable startup behaviors must be implemented in dedicated files under `handlers/` and invoked from `start.sh`.
- Do not add configuration knobs, feature flags, or optional toggles unless the user explicitly asks for them.
