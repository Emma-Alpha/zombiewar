# Repository Guidelines

## Project Structure & Module Organization

This is a Godot 4.7.1 2.5D game prototype. Keep runtime code in `scripts/`, grouped by feature (`player/`, `combat/`, `gameplay/`, `fx/`, `menu/`, and `ui/`). Matching reusable scenes belong in `scenes/`; data-driven configuration such as weapon and difficulty definitions belongs in `resources/`. Source models, textures, fonts, and audio live under `assets/`. Tests are split between `tests/unit/` and `tests/integration/`, with shared assertions in `tests/helpers/` and registration in `tests/test_runner.gd`. Treat `addons/` as third-party or plugin code; avoid modifying it unless the change specifically targets that dependency. Design notes and implementation plans live in `docs/`.

## Build, Test, and Development Commands

- `/Applications/Godot.app/Contents/MacOS/Godot --path .` launches the configured main scene.
- `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit` imports assets and catches scene or script parse errors.
- `/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd` runs the full custom test suite.
- `mkdir -p build/web && /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --export-release Web build/web/index.html` creates the Web export.

## Coding Style & Naming Conventions

Use GDScript with tabs for indentation and follow the existing Godot style. Name files, variables, and functions in `snake_case`; use `PascalCase` for `class_name` declarations and scene root types; use `UPPER_SNAKE_CASE` for constants. Add type annotations where they clarify public APIs or avoid Variant inference. Prefer small, feature-focused scripts and `res://` paths. Keep `.tscn` and `.tres` edits editor-generated when practical, and commit the associated `.uid` files.

## Testing Guidelines

Tests use lightweight `RefCounted` cases with a `run() -> Array[String]` method. Name files `test_<behavior>.gd`, place logic tests in `unit/`, and scene-contract tests in `integration/`. Register every new test in `TEST_PATHS` inside `tests/test_runner.gd`. Run the full headless suite before submitting changes; no coverage percentage is enforced, but new behavior and regressions should receive focused tests.

## Commit & Pull Request Guidelines

History follows Conventional Commit-style prefixes such as `feat:`, `fix:`, `test:`, `docs:`, and `chore:`. Keep subjects imperative and scoped to one logical change. Pull requests should summarize gameplay or architecture impact, list verification commands, link relevant issues or design notes, and include screenshots or short clips for visible scene, UI, animation, or VFX changes. Do not commit generated `build/` or `.godot/` contents.
