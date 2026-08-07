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

Zombie pathfinding uses the deterministic flow field in `scripts/sim/`
(`FlowFieldGrid` + `FlowField`): an XZ integer grid with multi-source BFS over
integer costs, rebuilt synchronously whenever a player crosses a cell boundary
or the blocker set is marked dirty. Runtime navigation baking does not
participate in the simulation layer, and no simulation code may call
`NavigationAgent3D`, `NavigationServer3D`, or any asynchronous bake: the
completion time of an async bake is itself nondeterministic and would break
lockstep replay.

Any system that adds, removes, moves, enables, or disables collision geometry
that blocks movement must mark the affected flow field cells dirty after the
geometry change, by routing a world AABB through
`SimWorld.set_blocker_world_rect()`. `PlaceItemService` placement and removal
and pickup chest appearance and disappearance go through this path. Missing a
dirty mark leaves zombies walking around obstacles that no longer exist.

Explosive barrels are the exception: they are simulation entities
(`SimWorld.spawn_barrel()`), and `SimWorld` owns their blocker rectangle end to
end -- blocked on registration, cleared on the exact tick they detonate. Their
hit count, damaged state, fuse (counted in **ticks**, never in seconds), chain
detonation, and zombie damage all live in the simulation; `ExplosiveBarrel` is a
presentation node plus the player damage source, driven by
`SimWorld.tick_barrel_events`. Never give a barrel node its own timer, its own
hit counter, or its own physics ray: wall-clock fuses land on different ticks on
different clients and desync every zombie the blast kills.

`NavigationWorldManager`, `NavigationChunk3D`, and `NavigationBakeState` are
**retired but retained**. They are still instantiated by `DemoArena` and still
respond to geometry-changed signals, but nothing in gameplay consumes their
navigation meshes. Do not build new features on them. They will be deleted once
the S3 synchronisation layer lands and confirms no other consumer exists.

When changing zombie movement behaviour, verify pursuit, wandering, unreachable
targets, blocked attack paths, and runtime blocker changes with
`tools/validation/validate_flow_field.gd`,
`tools/validation/validate_sim_collision.gd`, and
`tools/validation/validate_sim_determinism.gd`. When changing explosive barrels,
also run `tools/validation/validate_sim_barrel.gd`.

## Combat FX Render Warmup

Place new runtime combat VFX scenes that use meshes, custom shaders, GPU particles, or first-use animations under `scenes/fx/`. If the effect can appear during gameplay, its root script must implement `warmup_for_render(context)` and `finish_render_warmup()` so `CombatFxPrewarmer` discovers it automatically.

Warmup methods may only activate visual rendering. They must not play audio, deal damage, emit gameplay attack signals, consume input, mutate weapon spread, write saves, or depend on a live target. `finish_render_warmup()` must be safe to call during cleanup and restore the effect to an inactive state. Verify new warmable effects with the headless import check and focused in-game inspection.

## Testing Guidelines

The repository currently has no persistent automated test suite. Use the headless Godot editor command to catch import, scene, and script parse errors. Add focused tests only when a change has a stable, high-value behavior contract that is not coupled to frequently tuned gameplay numbers or presentation details.

Do not use CUA (computer-use or UI-control automation) to perform fully automated validation. Prefer headless Godot checks and focused source-level validation. When a visual or interactive result cannot be verified reliably from source-level checks, give the user a short, precise sequence of in-game operations to perform, ask them to capture the relevant screenshot, and analyze the screenshot they provide.

## Commit & Pull Request Guidelines

History follows Conventional Commit-style prefixes such as `feat:`, `fix:`, `test:`, `docs:`, and `chore:`. Keep subjects imperative and scoped to one logical change. Pull requests should summarize gameplay or architecture impact, list verification commands, link relevant issues or design notes, and include screenshots or short clips for visible scene, UI, animation, or VFX changes. Do not commit generated `build/` or `.godot/` contents.
