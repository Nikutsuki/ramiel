# Ramiel Documentation

- [User docs](user/README.md) — building apps with the public API.
- [Developer docs](dev/README.md) — internals, architecture, subsystem boundaries.

## Source of truth

- Public API: `src/root.zig`.
- Examples: `examples/`.
- Authoritative runtime entry point: `src/app.zig`.

## Targets

Zig 0.16.0-dev. Module name: `ramiel`.

## Common build steps

- `zig build check` — compile-only across all targets. Run after every change.
- `zig build test` — runs the test suite.
- `zig build run-<example>` — every directory under `examples/` (kebab-case) has a corresponding step.
- `zig build bench` — micro-benchmarks.
- `-Dtracy=true` — Tracy profiler hooks.
- `-Ddevtools=true` — DevTools overlay.

`glslc` must be on PATH (shaders compile as build deps).
