---
name: game-visual-qa
description: >
  Catch the defects that compile, run, deal damage, and log nothing — yet look broken on
  screen: muzzle flash detached from the barrel, weapons floating out of the hand, blood
  landing somewhere other than the hit, corpses sinking through the floor, effects pointing
  the wrong way, HUD overlapping at another resolution. Verifies assembly as geometry
  contracts in headless Godot, never by pixel-diffing screenshots. Use after adding or
  changing any model, effect, attachment point, animation event, or HUD element, when
  something "looks wrong but the code is fine", or as the visual acceptance pass before
  calling a feature done. For weapons specifically use weapon-qa.
---

# Visual QA — assembly defects, not art critique

This skill does not judge whether the game looks *good*. It catches whether the game looks
**wrong** — the class of defect where every code path runs, no error is logged, damage
resolves correctly, and the picture is still broken.

That class is the blind spot of automated verification. A test can confirm `fire()` was
called. It cannot confirm that **the shot looks like one event on screen**. This skill closes
that gap by turning "looks right" into assertions about transforms, bounds, and tick
alignment — the things that actually determine what gets drawn.

## The core method: geometry contracts, not screenshots

The tempting design is: run the game, screenshot it, compare pixel coordinates ("barrel at
x=843, flash at x=861, off by 18px"). **Do not build this.** Three reasons:

1. **Where does the ground truth come from?** To know the barrel's *correct* screen position
   you must project `MuzzleSocket.global_transform` to screen space. But once you can do that
   projection, you already hold the geometric truth — comparing transforms directly is
   strictly more accurate. The screenshot step only adds render timing, resolution,
   anti-aliasing, and particle jitter as noise.
2. **Pixel thresholds don't regress.** "18px" depends on resolution and camera distance.
   Change either and every threshold needs retuning. Transform assertions are resolution-
   independent and run in CI.
3. **This repo forbids it.** `AGENTS.md` rules out CUA / UI-control automation for
   validation. Headless checks and source-level validation first; anything that genuinely
   needs eyes goes to a human with precise steps.

So: **assert the assembly, ask a human about the aesthetics.**

```
Tier 1 — geometry contract   headless, in CI, ~80% of defects   ← build this
Tier 2 — human acceptance    precise steps + screenshot back    ← for what's left
```

## Tier 1 — what to assert, by domain

### Attachment QA — is the thing where it should be?

The chain from the character down to the effect spawn point must be unbroken, and every joint
must be checkable.

**Know this project's actual chain before asserting anything about it.** Weapons here are
**not** bone-attached. The gun *visual* belongs to the character model
(`Characters_Lis_SingleWeapon.gltf`, which carries `Knife / Pistol / Rifle / Shotgun / SMG`
nodes); the weapon scene is logic plus effect anchors only:

```
Player (CharacterBody3D)
├── VisualRoot → character model  ← the gun mesh lives in here
├── WeaponCollision (CollisionShape3D)   ← the gun's physical stand-in
├── FunctionalRayOrigin (Marker3D)
└── EquipmentController
     └── Pistol / Smg / Knife (Node3D, logic)
          ├── Muzzle (Marker3D)   ← synced onto the capsule each frame
          │    └── MuzzleFlash
          └── ShotAudio
```

The joint that silently fails is `WeaponDefinition.visual_node_name` →
`character_visual_root.find_child(...)` in `weapon_base.gd`. A typo leaves `visual_anchor`
null, `_sync_to_visual_anchor()` becomes a no-op, and the weapon plus its muzzle drift to the
world origin — **with no error logged**. Assert the anchor resolves, always.

If bone attachment is ever introduced, the chain becomes
`Skeleton3D → BoneAttachment3D → Weapon → MuzzleSocket` and each link gets the same treatment.

### VFX QA — does the effect start where the event happened?

- An effect parented to a socket must have an **identity local transform**. Any offset means
  it left the socket — and a stray drag in the editor leaves exactly this, silently.
- The effect's spawn position must equal the position the *simulation* used. In this repo
  `_fire()` derives both the ballistic origin and the flash position from one call to
  `_sync_muzzle_to_capsule()`; assert they stay the same point so nobody splits them later.
- Effect **orientation** must match what the simulation aims. Here muzzle direction is
  flattened to horizontal to match `WeaponMath.flat_direction` — assert `forward.y ≈ 0`.
- Impact effects (blood, sparks) must spawn at the reported hit position, not at the target's
  origin — those differ by a body radius and read as "blood coming out of the wrong spot".
- Pooled effects must be big enough for the fire rate, or they overwrite themselves and
  flicker under sustained fire.

### Animation QA — do the animation and the event agree?

- The damage frame of an attack animation must line up with the tick the simulation applies
  damage. Drift here reads as "the zombie hit me before it swung."
- Death animations must not sink through the floor or end mid-air.
- Animation clip names referenced from code must exist on the model. In this project both
  zombie models carry the same 16 clips (`Idle / Walk / HitReact / Punch / Death` …) — that
  parity is what makes a new zombie type a data-only change, so **assert it when adding a
  model**, don't assume it.

### Collision QA — does the hitbox match what you see?

- Collider bounds vs. mesh AABB, within a stated tolerance.
- A visually larger enemy with an unchanged collider reads as "my shots pass through it."
  (Note: in this repo the sim owns zombie radius; the scene `CollisionShape3D` is the
  presentation-side blocker. Changing one without the other is exactly this defect.)

### Camera QA

- Geometry between camera and player at the framing extremes.
- Camera bounds vs. the playable area — a `camera_bounds` smaller than where players can walk
  means the player leaves frame.

### HUD QA

- Anchored rects must not overlap at any supported aspect ratio; check the extremes, not just
  16:9.
- HUD must not cover the play area where the action happens.
- **Web-export-only text defects**: `assets/fonts/NotoSansSC-UI.ttf` has
  `allow_system_fallback=true`, so a missing glyph silently falls back on desktop and renders
  as tofu **only in browsers** — this class of bug cannot reproduce on the machine that
  introduces it. Run `tools/validation/validate_ui_font_coverage.gd` after adding any
  user-facing string.

## Tier 2 — what only eyes can settle

Hand these to the human as numbered steps plus a screenshot request, then analyse what comes
back. Do not assert them from source:

- clipping (hand through gun, weapon through wall, corpse through floor)
- floating or missing shadows
- proportion errors ("the tank zombie reads as a normal zombie standing closer")
- whether an effect *reads* as the event it represents
- whether the overall frame is legible during a full horde

Ask about the **experience**, not the implementation: "could you tell which zombie was the
tank?" beats "did the scale field apply?" — the player can only answer the first reliably,
and the first is what the defect actually is.

## Running it

Existing coverage to run before writing anything new:

```bash
# weapon assembly matrix — every weapon in the player's loadout
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script tools/validation/validate_weapon_assembly.gd

# muzzle flash orientation vs. simulated ballistics
… --script tools/validation/validate_muzzle_flash_orientation.gd
# HUD/menu scenes, screen bounds, camera math
… --script tools/validation/validate_shared_camera_scene.gd
… --script tools/validation/validate_player_screen_bounds.gd
# CJK glyph coverage (catches Web-only tofu)
… --script tools/validation/validate_ui_font_coverage.gd
```

When you add a new visual system, add its geometry contract to the matching validator rather
than writing a one-off check — the point is that the **next** asset gets checked automatically.

## Anti-patterns

- **Pixel-diffing screenshots.** See above. If you can compute the expected pixel, assert the
  transform instead.
- **Asserting an aesthetic.** "The flash is too small" is a design note, not a QA failure.
- **Checking that a function was called.** That is exactly the coverage this skill exists to
  supplement.
- **Tolerance inflation.** Widening a threshold until it passes converts a real defect into a
  permanently green test. If a contract is wrong, change the contract deliberately and say why.
- **Hardcoding the asset list.** Drive checks off the authored data (the loadout array, the
  map's zombie definitions) so new content is covered on arrival.
