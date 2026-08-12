---
name: zombie-crisis-reference
description: >
  The design reference for this project — what "feels like 《僵尸危机》/Boxhead" actually means,
  expressed as five checkable pillars (horde pressure, gun impact, weapon differentiation,
  zombie differentiation, frame stability) plus the project's hard architectural constraints
  that any feel change must not violate. Use when judging whether a change makes the game
  more or less like the reference, when tuning waves/weapons/zombies/feedback, when someone
  asks "is this done?", or before writing any gameplay-feel code in this repo. Read this
  BEFORE game-feel, game-ai, level-design, or audio-design — it says what "good" means here.
---

# Zombie Crisis — design reference

The public gamedev skills know *how* to build horde pressure, juice, and enemy variety. They
do not know what **this** game is supposed to feel like, and they do not know that this repo
runs a deterministic lockstep simulation that punishes the obvious way to add juice. This
skill supplies both.

**Prime directive: a feature existing is not the feature being done.** Every judgement in this
repo is made against player experience, never against "the code path exists". A wave system
that spawns waves is not a wave system that creates pressure. A second weapon is not weapon
variety. Check the pillars, not the checklist.

## The core loop

```
spot horde → reposition → shoot → hit → knockback/kill/explode
    → drop/score → bigger horde → stronger weapon → repeat
```

Every arrow is a promise to the player. The loop breaks wherever an arrow stops escalating:
if the horde never gets bigger, "stronger weapon" has nothing to answer; if weapons never get
stronger, "bigger horde" is just attrition. **The two escalation arrows must move together.**

## The five pillars

Judge any build against these. Each has a failure signature you can actually detect.

### 1. Horde pressure — does the space close in?

The reference feeling is the player's usable floor area shrinking. Not this:

```
Z  Z  Z  Z            ← a queue. player backpedals, wins, feels nothing.
```

but this:

```
        Z
   Z         Z
Z      PLAYER      Z   ← arrival from multiple bearings, over time
   Z         Z
        Z
```

**Failure signatures**
- One wave definition looping forever → wave 30 and wave 3 are the same fight.
- All spawns land on one tick (`spawn_interval_ticks = 0`) → one face-rush, then silence,
  instead of continuous pressure.
- Zombie count rises but arrival bearings don't → the horde is bigger, not tighter.
- No rest beat between waves → pressure with no contrast reads as flat, not intense.

**Where it lives:** `resources/maps/*/*.tres` (`waves`, `spawn_points`,
`inter_wave_delay_ticks`, `maximum_active_zombies`), driven by
`scripts/sim/sim_wave_director.gd`. Pairs with the `level-design` skill (pacing curve) and
`game-ai` (arrival behaviour).

### 2. Gun impact — is one shot satisfying on its own?

A single trigger pull must fire a *layered* response. The reference chain:

```
input → muzzle flash → gun sound → recoil/spread kick → tracer
      → zombie flash/blood → knockback → camera impulse → hit-stop
      → death animation → corpse/ground blood
```

**Failure signature:** the mechanic is correct and the game still feels limp. That is almost
always *missing layers*, not wrong numbers. Count the links present before tuning any value.

**Rule:** never fix weak impact by raising damage. Damage is a balance dial; impact is a
feedback-layer count. Raising damage to fix feel silently destroys pillar 3.

**Where it lives:** `scripts/fx/` (muzzle flash, tracer, blood, ground blood, sfx pool),
`scripts/camera/follow_camera.gd` (`add_shot_impulse`), `scripts/combat/hit_response_math.gd`
(knockback), `scripts/combat/zombie_target.gd` (`play_hit_reaction`). Pairs with `game-feel`.

### 3. Weapon differentiation — does the weapon change how you play?

Weapons must differ in **role**, not in a damage number.

```
手枪    precise / single-target / infinite ammo / safe fallback
冲锋枪  suppression / high rate / spread growth / ammo pressure
霰弹枪  close range / knockback / cone clear / punishes bad positioning
火箭筒  AoE / horde deletion / scarce / self-danger
地雷/油桶  setup / zoning / turn the map into the weapon
```

**The bullets-to-kill test.** For every weapon, compute `ceil(zombie_hp / damage)`. If two
weapons produce the same number against the baseline zombie, **they are the same weapon** to
the player regardless of their stat sheet. This is the single fastest differentiation check
in the repo.

**Failure signatures**
- Picking up the "better" weapon lowers effective DPS or adds ammo anxiety with no new
  capability → the upgrade reads as a downgrade.
- Fire rate that contradicts the weapon's identity (an SMG below ~8 shots/sec does not read
  as an SMG no matter what the label says).
- `base_spread` / `max_spread` / `spread_increase_per_shot` identical across weapons → the
  recoil system exists but is not being used to differentiate.

**Where it lives:** `resources/weapons/*.tres` against
`scripts/combat/weapons/ranged_weapon_definition.gd`.

### 4. Zombie differentiation — does the enemy change your strategy?

Not skins with different HP. Each type must force a *different player answer*.

```
Normal    baseline pressure          → answer: aim
Runner    closes distance fast       → answer: pre-fire, keep moving
Tank      slow, high HP, blocks      → answer: focus fire or route around
Exploder  detonates on contact       → answer: kill at range, never melee
Ranged    hits from afar             → answer: break line, close in
Spawner   creates more units         → answer: prioritise the source
```

**The strategy test.** For each type ask: *what does the player do differently when this one
appears?* If the answer is "shoot it, but longer", it is a reskin, not a type.

**Failure signatures**
- One zombie definition in `resources/zombies/`.
- Difficulty tiers that differ only in movement speed → "harder" means "the same fight,
  faster", which raises frustration without raising interest.
- FSM with only `WANDER / APPROACH / ATTACK` and no separation, flanking, or grouping → every
  type, however statted, arrives the same way.

**Where it lives:** `resources/zombies/*.tres`, `resources/difficulty/*.tres`,
`scripts/combat/zombie_behavior_math.gd`. Pairs with `game-ai`.

### 5. Frame stability under load — does the fantasy survive the horde?

This genre's whole promise is *many* enemies. Frame collapse at high counts doesn't degrade
the game, it deletes the premise.

**Current state (already solved — do not re-solve):** `scripts/render/zombie_renderer.gd`
runs distance LOD — nearest `NEAR_LOD_COUNT` (48) get skinned `ZombieTarget` scenes, the rest
render as `MultiMeshInstance3D` static poses; `scripts/fx/combat_fx_prewarmer.gd` pre-compiles
shader/particle pipelines to kill first-use hitches; FX and SFX are pooled.

**Rule:** treat performance as a *regression* check here, not an optimisation project. Run
`tools/validation/validate_combat_frame_stability.gd`. Only reach for the
`performance-optimization` skill if it fails or if a new system adds per-zombie per-frame
work. Do not add MultiMesh/pooling advice that already exists.

## Hard constraints — the part public skills will get wrong

This project runs a **deterministic, tick-driven simulation** shared across clients over the
network. `AGENTS.md` is authoritative; these are the rules that specifically collide with
"make it feel better" work. Violating one produces a desync, not a bug you'll notice locally.

1. **Never `Engine.time_scale` for hit-stop.** It scales the whole engine, including anything
   tick-driven, and it will not be scaled identically on other clients. Hit-stop must be
   **presentation-layer only**: freeze the near-LOD `ZombieTarget` `AnimationPlayer`, the
   camera, and FX — never `SimClock`, never the tick loop.
2. **Never add a `Timer` or wall-clock delay to gameplay state.** Waves, zombie death events,
   fixed pickup respawns, and barrel fuses advance by **simulation tick only**. A wall-clock
   fuse lands on different ticks on different clients.
3. **Never use presentation-layer RNG for gameplay outcomes.** Drops, spawn placement, and
   spread go through the deterministic RNG. `randf()` in a feel patch is a desync.
4. **Sim-reachable files may not call `sin`/`cos`/`atan2`/`Vector2.rotated()`** — use
   `SimMath`. The sim path reaches beyond `scripts/sim/`: `zombie_behavior_math.gd`,
   `explosion_math.gd`, `hit_response_math.gd`, `melee_attack_cycle.gd`, and the static half
   of `weapon_spread_state.gd` are all bound by this. New sim-reachable files must be added to
   `SIM_REACHABLE_FILES` in `tools/validation/validate_sim_math.gd`.
5. **Physics overlap is not a gameplay event.** Bodies are in different places on different
   clients (local player runs ahead, remotes interpolate). Claiming, pickup, and hit
   resolution belong in `SimWorld`, not in an `Area3D` signal.
6. **Any geometry change that blocks movement must mark flow-field cells dirty** via
   `SimWorld.set_blocker_world_rect()`, or zombies path around obstacles that no longer exist.

**Practical consequence for feel work:** rank changes by how deep they cut.

```
data-only (.tres)          → safest, fastest, usually highest ROI    ← start here
presentation layer (fx/, camera/, render/)  → safe if it touches no gameplay state
simulation layer (scripts/sim/, sim-reachable math)  → needs determinism validation
network protocol (scripts/net/, server/src/lib/protocol.ts)  → bump PROTOCOL_VERSION, run gates
```

## External skills: what to take and what will break this project

The installed skill libraries (`awesome-gamedev-agent-skills`, `gd-agentic-skills`) are written
for the *typical* Godot game. This project is not typical: it runs a deterministic, tick-driven
simulation shared across clients. Several of their strongest "NEVER" rules are **correct advice
that is wrong here**, and following them produces desyncs that never reproduce locally.

**Reject these, with reasons:**

| External advice | Why it breaks this project |
|---|---|
| "NEVER pathfind for hundreds of agents on the main thread — use async navigation / `WorkerThreadPool`" | Async completion timing is nondeterministic and would break lockstep replay. `AGENTS.md` forbids it outright. The flow field already makes pathing cost independent of zombie count. |
| "Generate content on a background thread, parse on the main thread" | Same reason. Any gameplay state produced off the tick loop diverges between clients. |
| "Use `MultiplayerSynchronizer` / sync a UID and look it up client-side" | This project does not use Godot's high-level multiplayer at all. Sync goes through the custom frame channel. |
| "Use a `Timer` for wave countdowns / cooldowns / fuses" | Wall-clock timers land on different ticks on different clients. Everything gameplay-facing counts **ticks**. |
| "Fog of war to hide the edge of the world" | Fixed top-down arena with camera bounds; there is no unexplored space to hide. |

**Take these — they apply and matter:**

- **`duplicate(true)` on base stat Resources.** Godot Resources are shared instances; mutating one
  `.tres` at runtime changes it for every entity that references it — the "damage one, damage all"
  bug. Directly relevant to roguelite upgrades that modify weapon stats.
- **Modifier stacking with explicit types** (ADDITIVE / MULTIPLICATIVE / OVERRIDE) and a unique id
  per modifier so it can be removed. Recompute reactively on change, never in `_process`.
- **Shuffle bag instead of `pick_random()`** for meaningful drops — prevents a run being ruined by
  a statistically legal but miserable streak. Must be driven by the deterministic RNG here.
- **Keep meta-progression subtle (+5–15%), not +100%** — otherwise skill stops mattering.
- **Separate run state from meta state** so a run's temporary power never leaks into the profile.
- **Every run must be winnable** — provide mitigation (rerolls, pity timers) rather than pure RNG.

**The general rule:** external skills tell you *how* a technique is normally implemented. This
file and `AGENTS.md` decide *whether that technique is allowed here*. When they conflict, the
project's determinism rules win, and the right move is to find a tick-driven equivalent — not to
relax the rule.

## Where the design data actually lives

| Pillar | Files |
|---|---|
| Waves, spawn points, drops, caps | `resources/maps/demo/demo_map.tres` |
| Weapons | `resources/weapons/{knife,pistol,smg}.tres` |
| Zombies | `resources/zombies/*.tres` |
| Difficulty | `resources/difficulty/zombie_{easy,normal,hard}.tres` |
| Pickups | `resources/pickups/*.tres` |
| Wave state machine | `scripts/sim/sim_wave_director.gd` |
| Zombie FSM | `scripts/combat/zombie_behavior_math.gd` |
| Impact feedback | `scripts/fx/`, `scripts/camera/follow_camera.gd` |
| Scoring metric | `team_wave` (wave reached) — `server/src/room_do.ts` |

Because waves, weapons, zombies, difficulty, and drops are **all data**, the majority of
reference-gap fixes are `.tres` edits with no code risk. Prefer them.

## Using this skill

When asked to judge, tune, or extend gameplay:

1. Read the relevant pillar above and name its failure signature explicitly.
2. Check the data files before reading code — most gaps are visible in `.tres`.
3. Classify the fix by depth (data / presentation / simulation / protocol) and prefer the
   shallowest that actually solves it.
4. Compose with the public skill for technique: `level-design` (pacing), `game-feel` (juice),
   `game-ai` (enemy behaviour), `audio-design` (mix), `godot-resources` (data modelling).
   Those skills supply *how*; this one supplies *what good means* and *what not to break*.
5. To find gaps rather than fix a named one, use `zombie-crisis-playtest`.
