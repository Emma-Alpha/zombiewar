# Repository Guidelines

## Project Structure & Module Organization

This is a Godot 4.7.1 2.5D game prototype. Keep runtime code in `scripts/`, grouped by feature (`player/`, `combat/`, `gameplay/`, `fx/`, `menu/`, and `ui/`). Matching reusable scenes belong in `scenes/`; data-driven configuration such as weapon and difficulty definitions belongs in `resources/`. Source models, textures, fonts, and audio live under `assets/`. Treat `addons/` as third-party or plugin code; avoid modifying it unless the change specifically targets that dependency. Design notes and implementation plans live in `docs/`.

## Build, Test, and Development Commands

- `/Applications/Godot.app/Contents/MacOS/Godot --path .` launches the configured main scene.
- `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit` imports assets and catches scene or script parse errors.
- `mkdir -p build/web && /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --export-release Web build/web/index.html` creates the Web export.

## Coding Style & Naming Conventions

Use GDScript with tabs for indentation and follow the existing Godot style. Name files, variables, and functions in `snake_case`; use `PascalCase` for `class_name` declarations and scene root types; use `UPPER_SNAKE_CASE` for constants. Add type annotations where they clarify public APIs or avoid Variant inference. Prefer small, feature-focused scripts and `res://` paths. Keep `.tscn` and `.tres` edits editor-generated when practical, and commit the associated `.uid` files.

## 3D Runtime Navigation

Each playable 3D world owns a scene-level navigation manager; do not use an Autoload for world navigation state. Split navigation into registerable chunk lifecycle units that all share the current `World3D` navigation map so adjacent regions can form continuous paths.

Bake navigation meshes asynchronously at runtime from simplified static collision geometry. Do not parse high-polygon visual models when equivalent gameplay collision shapes exist. Keep the previous usable mesh active during a rebake, prevent concurrent bakes for the same chunk, and coalesce repeated dirty or rebake requests.

Any system that adds, removes, moves, enables, or disables collision geometry used by navigation must mark the affected navigation chunk dirty after the geometry change. `NavigationAgent3D` avoidance remains disabled by default and should only be enabled for a feature that explicitly requires local crowd avoidance.

When changing navigation behavior, verify pursuit, wandering, unreachable targets, runtime bake failure behavior, and attacks blocked by world obstacles. Navigation-unavailable fallback behavior must not become the permanent fallback for an unreachable target after a valid navigation map exists.

## Combat FX Render Warmup

Place new runtime combat VFX scenes that use meshes, custom shaders, GPU particles, or first-use animations under `scenes/fx/`. If the effect can appear during gameplay, its root script must implement `warmup_for_render(context)` and `finish_render_warmup()` so `CombatFxPrewarmer` discovers it automatically.

Warmup methods may only activate visual rendering. They must not play audio, deal damage, emit gameplay attack signals, consume input, mutate weapon spread, write saves, or depend on a live target. `finish_render_warmup()` must be safe to call during cleanup and restore the effect to an inactive state. Verify new warmable effects with the headless import check and focused in-game inspection.

## Testing Guidelines

The repository currently has no persistent automated test suite. Use the headless Godot editor command to catch import, scene, and script parse errors. Add focused tests only when a change has a stable, high-value behavior contract that is not coupled to frequently tuned gameplay numbers or presentation details.

Do not use CUA (computer-use or UI-control automation) to perform fully automated validation. Prefer headless Godot checks and focused source-level validation. When a visual or interactive result cannot be verified reliably from source-level checks, give the user a short, precise sequence of in-game operations to perform, ask them to capture the relevant screenshot, and analyze the screenshot they provide.

## Commit & Pull Request Guidelines

History follows Conventional Commit-style prefixes such as `feat:`, `fix:`, `test:`, `docs:`, and `chore:`. Keep subjects imperative and scoped to one logical change. Pull requests should summarize gameplay or architecture impact, list verification commands, link relevant issues or design notes, and include screenshots or short clips for visible scene, UI, animation, or VFX changes. Do not commit generated `build/` or `.godot/` contents.
