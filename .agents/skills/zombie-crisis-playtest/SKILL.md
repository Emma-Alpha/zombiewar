---
name: zombie-crisis-playtest
description: >
  Run a development health check on this game instead of writing more code — audit the build
  against the design reference, rank what is actually wrong by ROI, and return the top
  problems with a P0, plus the exact in-game steps a human must perform for anything not
  verifiable from source. Use when asked to review/audit/health-check the game, to decide
  what to build next, when someone asks "what is missing" / "why isn't it fun" / "is this
  done", or after finishing a batch of features. Also use to pick the next task when the
  direction is unclear. Read zombie-crisis-reference first — it defines what good means.
---

# Zombie Crisis — playtest & triage

A build that compiles is not a build that plays. This skill runs the loop that finds *what is
not fun*, ranks it, and picks the next thing to do. **While running it you are auditing, not
implementing** — produce findings first, and only act after the P0 is agreed.

```
inspect data → machine-verify → judge against pillars → rank by ROI
     → Top N problems → P0 → fix only the P0 → re-check
```

Fixing three things at once makes it impossible to tell which one helped. Fix the P0, re-run,
re-rank.

## Verification boundary — read this before running anything

`AGENTS.md` forbids CUA / UI-control automation for validation in this repo. That is a
standing constraint, not a preference. So this skill splits every claim into three tiers:

| Tier | How it's verified | Who does it |
|---|---|---|
| **Data facts** | read `.tres` / `.gd`, compute | you, directly |
| **Machine checks** | headless Godot + `tools/validation/*.gd` | you, via Bash |
| **Feel claims** | actually playing the build | **the human**, from your written steps |

**Never assert a feel claim you did not verify.** Write "the data implies X; confirm by doing
Y" rather than "the game feels X". Getting this wrong is worse than finding nothing, because
it launders a guess into a finding.

## Step 1 — Machine checks

Baseline (always):

```bash
# import + parse errors. Plugin "rp_font is null" lines are known noise.
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit

# frame stability under combat load
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script tools/validation/validate_combat_frame_stability.gd
```

Then pick by what changed (`ls tools/validation/` for the full set of 39):

| Changed area | Run |
|---|---|
| Map / wave / spawn data | `validate_map_definitions`, `validate_sim_wave_director`, `validate_demo_map_data_driven` |
| Zombie types | `validate_sim_zombie_types`, `validate_zombie_renderer_types`, `validate_zombie_target_selector` |
| Zombie movement / blockers | `validate_flow_field`, `validate_sim_collision`, `validate_sim_determinism` |
| Any sim-reachable math | `validate_sim_math`, `validate_sim_determinism`, `validate_deterministic_rng` |
| Weapons / audio | `validate_weapon_assembly`, `validate_automatic_weapon_audio`, `validate_muzzle_flash_orientation`, `validate_equipment_cycle` |
| Hit-stop / feedback layers | `validate_hit_stop` |
| Models, effects, attachments, HUD layout | `validate_weapon_assembly`, `validate_ui_font_coverage` — and load `game-visual-qa` |
| Drops / pickups / chests | `validate_random_pickup_drops`, `validate_pickup_definitions`, `validate_sim_death_events`, `validate_sim_chest_claim`, `validate_sim_pickup_respawn` |
| Barrels | `validate_sim_barrel` |
| Net / protocol | `validate_online_frame_sync`, `validate_online_reconnect_resume` |
| User-facing text | `validate_ui_font_coverage` (Web-export-only tofu bugs cannot reproduce locally) |
| Camera / screen bounds | `validate_shared_camera_math`, `validate_shared_camera_scene`, `validate_player_screen_bounds` |

Runtime logs are available through the `godot_*` MCP tools (`godot_doctor`,
`godot_query_runtime_logs`) — these read state, they are not UI automation, so they are in
bounds. Driving menus/gameplay programmatically is not.

## Step 2 — Data audit (fastest signal in the repo)

Most reference gaps are visible in `.tres` before any code is read.

**Wave curve** — `resources/maps/*/*.tres`
- How many wave definitions? One + `end_mode = 1` (LOOP) means **there is no difficulty
  curve**, only repetition — and the leaderboard metric (`team_wave`) becomes meaningless.
- `spawn_interval_ticks = 0` means the whole wave lands on **one tick** (see the
  `if spawn_interval_ticks > 0: return` early-out in `sim_wave_director.gd`). That is a face
  rush, not sustained pressure.
- Does composition change across waves, or only count?

**Bullets-to-kill table** — `resources/weapons/*.tres` × `resources/zombies/*.tres`

```
ceil(zombie.max_health / weapon.damage)   for every pair
```

Two weapons with the same number against the baseline zombie **are the same weapon**. Also
check `attacks_per_second` against the weapon's identity, and whether
`base_spread_degrees` / `max_spread_degrees` / `spread_increase_per_shot_degrees` actually
differ — an unused recoil system is a differentiation dimension left on the floor.

**Zombie roster** — `resources/zombies/`, `resources/difficulty/`
- One definition = pillar 4 fails outright.
- Difficulty tiers differing only in `perception_move_speed` = "harder" means "same fight,
  faster".

**Feedback layer count** — grep before judging feel:

```bash
grep -rn "hit_stop\|hitstop\|time_scale\|freeze_frame" scripts scenes   # hit-stop present?
grep -rn "shake\|impulse" scripts/camera scripts/combat                 # camera response?
grep -rn "knockback" scripts                                            # knockback?
ls assets/sfx/**/ ; ls -la default_bus_layout.tres 2>/dev/null          # audio layers/buses?
```

A missing *layer* explains weak impact far more often than a wrong *number*.

## Step 3 — Known data-model ceilings

Do not propose a data-only fix that the Resource cannot express. Current ceilings:

- **`ZombieDefinition` has only `max_health` + `move_speed_scale_per_10000`.** So Runner
  (fast/fragile) and Tank (slow/tough) are **pure data**. Exploder, Ranged, and Spawner need
  new exports **and** simulation work in `SimWorld` — they are not data edits. Say so instead
  of promising them cheap.
- **`RangedWeaponDefinition` already has `penetration_damage_coefficient` and
  `max_penetration_count`, plus the full ballistic-spread group, `attack_range`, and ammo.**
  These are unused differentiation dimensions available for free.
- **No multi-pellet field exists**, so a true shotgun needs code, not data. A knockback-heavy
  short-range weapon with high spread is the data-only approximation.
- Multi-type wave entries, per-type drop rules, and per-type renderer buckets are already
  supported (`wave_zombie_entry_definition.gd`, `map_zombie_death_rule_definition.gd`,
  `validate_sim_zombie_types`) — adding a zombie *type* does not require new systems.

## Step 4 — Rank by ROI

Sort findings by **player-experience impact ÷ change depth**.

```
depth 1  data-only (.tres)                       ← almost always wins
depth 2  presentation (scripts/fx, camera, render, ui)
depth 3  simulation (scripts/sim + sim-reachable math)   → determinism validation required
depth 4  protocol (scripts/net + server/src/lib)         → PROTOCOL_VERSION bump + gates
```

Tie-breakers, in order:
1. **Does it break the core loop?** A broken escalation arrow outranks any polish item.
2. **Does it affect every session?** Wave-curve flatness hits 100% of play; a rare bug doesn't.
3. **Is it reversible?** Data edits are; protocol changes aren't.

Explicitly **de-prioritise already-solved areas.** Zombie render LOD, FX pre-warm, and pooling
are done (`zombie_renderer.gd`, `combat_fx_prewarmer.gd`). Re-recommending object pooling here
is noise — check `validate_combat_frame_stability` and move on unless it fails.

## Step 5 — Report format

```markdown
## Verification boundary
What was machine-checked vs. what needs human play.

## Findings (worst first)
### P0-n · <one-line symptom in player terms>
Evidence: <file:line, data values, computed numbers>
Why it matters: <which pillar, which failure signature>
Depth: <data | presentation | simulation | protocol>

## Top 3 by ROI
1. ... 2. ... 3. ...

## Needs your hands
<numbered in-game steps + exactly what to look for / screenshot>
```

Rules for the report:
- Lead with the symptom a player would describe, not the code defect.
- Every finding cites a file, a line, or a computed number. No vibes.
- State what you did **not** check.
- Never report "N features implemented" as progress. Report which pillars moved.

## Step 6 — Human verification requests

For anything in the feel tier, hand over precise steps, not "please test it":

> 1. Launch: `/Applications/Godot.app/Contents/MacOS/Godot --path .`
> 2. Main menu → 单人 → Demo 检查站
> 3. Press `T` to force a wave. Stand at the arena centre and do not move.
> 4. Watch how the horde arrives: all at once from four corners, or in a stream?
> 5. Screenshot at ~3s and ~8s after the wave starts.
> 6. Tell me: could you keep backing up, or did the space actually close in?

Then analyse the screenshots they return. Ask about *the experience* ("could you keep backing
up?"), not about the implementation ("did the spawn interval work?") — the player can only
report the former reliably, and the former is what the pillar is about.

## Anti-patterns

- **Continuing to code during a playtest pass.** The output of this skill is findings.
- **Reporting the absence of a feature as a finding without tying it to a pillar.** "There is
  no shotgun" is not a finding; "every weapon kills the baseline zombie in 2 shots, so pickups
  read as sidegrades" is.
- **Claiming a feel outcome from source alone.**
- **Batching fixes.** One P0 at a time, then re-check.
- **Fixing weak impact by raising damage.** That trades pillar 2 for pillar 3.
