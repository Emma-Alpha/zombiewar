# Repository Guidelines

## Project Structure & Module Organization

This is a Godot 4.7.1 2.5D game prototype. Keep runtime code in `scripts/`, grouped by feature (`player/`, `combat/`, `gameplay/`, `fx/`, `menu/`, and `ui/`). Matching reusable scenes belong in `scenes/`; data-driven configuration such as weapon and difficulty definitions belongs in `resources/`. Source models, textures, fonts, and audio live under `assets/`. Treat `addons/` as third-party or plugin code; avoid modifying it unless the change specifically targets that dependency. Design notes and implementation plans live in `docs/`.

## Map Runtime Architecture

Gameplay map data comes from `MapDefinition`; `GameplayArena` is the generic
host, and `DemoMap` is the default map wrapper scene. The map runtime assembly
may bake `place_item_obstacle` geometry into `SimWorld` only when it is inside
the current map content root. `ExplosiveBarrel` is excluded because the
simulation owns barrel blockers for their complete lifecycle.

Wave scheduling, zombie death events, and fixed pickup respawns advance only
by simulation tick. Do not use a `Timer` or presentation-layer RNG for any of
these gameplay-state transitions.

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
or the blocker set is marked dirty. Godot's built-in navigation agents,
navigation server, navigation regions, and runtime baking are not part of the
gameplay architecture. Do not restore them or introduce asynchronous navigation
work: completion timing is nondeterministic and would break lockstep replay.

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

Simulation code calls `SimMath` for trigonometry, never `sin`, `cos`, `atan2`,
or `Vector2.rotated()`. IEEE 754 does **not** require transcendental functions
to be correctly rounded, so the platform libm behind those built-ins may differ
in the last bit between a Web export's wasm, glibc on x86, and Bionic on ARM --
and zombie facing and weapon spread both feed the frame hash. `sqrt`,
`normalized()`, `length()`, and `distance_to()` are exempt and should stay as
they are: the standard does require correct rounding for `sqrt` and the basic
operations, so they are already identical everywhere. Note the simulation
reaches past `scripts/sim/` -- `zombie_behavior_math.gd`, `explosion_math.gd`,
`hit_response_math.gd`, `melee_attack_cycle.gd`, and the static half of
`weapon_spread_state.gd` are all on the sim path and bound by the same rule.
`tools/validation/validate_sim_math.gd` measures `SimMath` against the built-ins
and greps the sim-reachable file list for banned calls; add new sim-reachable
files to `SIM_REACHABLE_FILES` there.

When changing zombie movement behaviour, verify pursuit, wandering, unreachable
targets, blocked attack paths, and runtime blocker changes with
`tools/validation/validate_flow_field.gd`,
`tools/validation/validate_sim_collision.gd`, and
`tools/validation/validate_sim_determinism.gd`. When changing explosive barrels,
also run `tools/validation/validate_sim_barrel.gd`.

## Online Multiplayer

The backend lives in `server/` (Cloudflare Worker + D1 + Durable Objects) and is
deployed separately from the game. See `server/README.md` for the deploy steps,
the anti-cheat boundary, and the protocol-drift gates.

The room Durable Object owns the tick counter and pumps one frame every 50 ms.
A client advances its simulation by **exactly one tick per frame received** and
stalls when the queue is empty. Never advance a tick the server has not sent:
inventing a tick nobody else has is the definition of a desync.

Commands are **merged** into the pending slot, never overwritten
(`mergeCommand` in `server/src/lib/protocol.ts`). A client that stalled and
caught up sends one command per frame it consumed, so several land between two
pumps; taking only the last silently eats the shots the others carried. Held
bits take the newest value, edge bits accumulate, events concatenate. The two
bit classes are `STICKY_BITS` and `EDGE_BITS`, and `EDGE_BITS` must stay equal
to the client's `ONE_SHOT_BITS`.

A rejoining client is walked forward, never dropped in at the live tick. The
room keeps `FRAME_HISTORY_LIMIT` (600 = 30 s) broadcast frames; `join` carries
`resume_tick`, the last tick the client actually applied, and the room replays
everything after it as `backfill` messages before the roster goes out. A gap
older than the history is refused with close code 4007 rather than served
partially -- landing a client on a tick it never simulated its way to is the
desync the replay exists to prevent. Frames are remembered **as the bytes that
were broadcast**: `pumpFrame` strips edges off the command objects a frame
references immediately after sending it, so holding the object replays a frame
that never went out. Two consequences for anything touching this path: the
client's frame queue must stay at least `FRAME_HISTORY_LIMIT` deep or a full
replay is clipped at enqueue time, and `GameplayArena`'s catch-up loop must stay
wall-clock budgeted or several hundred replayed ticks freeze the frame. Verify
with `tools/validation/validate_online_reconnect_resume.gd`.

Player position is an **input**, not an output. `SimWorld.set_player_snapshot()`
already consumes quantised player coordinates, so every client feeds the
simulation the position that came over the wire -- including for its own player,
whose body is allowed to run ahead locally for feel. This is what makes
`move_and_slide()` free to be non-deterministic, and it is the reason this sync
layer is a fraction of the size of a full lockstep one.

Anything that changes gameplay state in online mode must reach the simulation
through a frame, never directly:

- Weapon fire, melee, and spread resets are buffered by
  `GameplayArena._buffer_local_sim_request()` and applied when they come back.
- A manual wave request sets `pending_wave_request`; the server ORs it into a
  frame so every client queues the wave on the same tick.
- Automatic wave progression is owned by `SimWaveDirector` and counted in
  simulation ticks; `GameplayArena` must not add a wall-clock wave timer.
- The room seed comes from the room. A client that picks its own desyncs by
  construction.

`LobbyProtocol.QUANT` must stay equal to `SimWorld.POSITION_QUANTIZATION`, and
`LobbyProtocol.TICK_HZ` must stay the reciprocal of `SimClock.TICK_SECONDS`.
When changing anything in `scripts/net/` or `server/src/lib/protocol.ts`, bump
`PROTOCOL_VERSION` on both sides and run
`tools/validation/validate_online_frame_sync.gd`, which reads the TypeScript
source directly and diffs every shared constant against the GDScript copy.

Supply chest claiming lives in `SimWorld._resolve_chest_claims()`, not in
`PickupChest`'s `ClaimArea`. A physics overlap is a presentation-layer event and
the players' bodies are not in the same place on every client -- the local one
runs ahead, remote ones are interpolated toward their networked position -- so
overlap-driven claiming hands the same chest to different players on different
frames. A chest is also blocker geometry, so its removal rebuilds the flow field;
claiming it on different ticks made every client's zombies walk different paths.
That is what "the two screens show different drops and different alive counts"
actually was. Ties are broken by lowest slot index, never by comparing float
distances. Register every chest that can be claimed with `SimWorld.spawn_chest()`
and drive the reward off `tick_chest_events`.

Known gap: runtime item placement (`PlaceItemService`) is driven per physics
frame rather than per tick, so a placement made while moving can land on
different cells across clients. It is detected by the frame-hash cross-check,
not prevented. Route it through the frame channel before relying on it online.

## UI Font Coverage

`assets/fonts/NotoSansSC-UI.ttf` is a subset of Noto Sans SC. Its import sets
`allow_system_fallback=true`, so a missing glyph silently falls back to a system
CJK font on desktop and renders as tofu **only in the Web export** -- meaning
this class of bug cannot reproduce on the machine that introduces it. The subset
therefore covers GB2312 level 1 plus every character the project's strings use,
not merely the characters in use at the moment it was generated: cutting it to
"what is used today" is exactly how the previous 127-character subset shipped a
main menu that read 「▯▯游戏」 in browsers.

Run `tools/validation/validate_ui_font_coverage.gd` after adding user-facing
text. If it reports missing glyphs, regenerate the subset from a full Noto Sans
SC rather than adding the characters one at a time. Changing the `.ttf` requires
a `--headless --editor --quit` pass before the new glyphs take effect; Godot
otherwise keeps serving the cached `.godot/imported/*.fontdata`.

## Combat FX Render Warmup

Place new runtime combat VFX scenes that use meshes, custom shaders, GPU particles, or first-use animations under `scenes/fx/`. If the effect can appear during gameplay, its root script must implement `warmup_for_render(context)` and `finish_render_warmup()` so `CombatFxPrewarmer` discovers it automatically.

Warmup methods may only activate visual rendering. They must not play audio, deal damage, emit gameplay attack signals, consume input, mutate weapon spread, write saves, or depend on a live target. `finish_render_warmup()` must be safe to call during cleanup and restore the effect to an inactive state. Verify new warmable effects with the headless import check and focused in-game inspection.

## Testing Guidelines

The repository currently has no persistent automated test suite. Use the headless Godot editor command to catch import, scene, and script parse errors. Add focused tests only when a change has a stable, high-value behavior contract that is not coupled to frequently tuned gameplay numbers or presentation details.

Do not use CUA (computer-use or UI-control automation) to perform fully automated validation. Prefer headless Godot checks and focused source-level validation. When a visual or interactive result cannot be verified reliably from source-level checks, give the user a short, precise sequence of in-game operations to perform, ask them to capture the relevant screenshot, and analyze the screenshot they provide.

## Commit & Pull Request Guidelines

History follows Conventional Commit-style prefixes such as `feat:`, `fix:`, `test:`, `docs:`, and `chore:`. Keep subjects imperative and scoped to one logical change. Pull requests should summarize gameplay or architecture impact, list verification commands, link relevant issues or design notes, and include screenshots or short clips for visible scene, UI, animation, or VFX changes. Do not commit generated `build/` or `.godot/` contents.
