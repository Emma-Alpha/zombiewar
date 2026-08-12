---
name: weapon-qa
description: >
  The per-weapon acceptance pass for this shooter — run the full assembly matrix over every
  weapon (visual anchor, muzzle socket, flash alignment, ballistic origin, tracer pool, shot
  audio polyphony, spread identity, bullets-to-kill) so a new gun can never ship "it fires
  and deals damage" while the flash floats beside the barrel. Use when adding, porting, or
  rebalancing a weapon, when a gun feels wrong, or before declaring weapon work done. Pairs
  with game-visual-qa for the geometry method and zombie-crisis-reference for what the
  weapon is supposed to feel like.
---

# Weapon QA — the per-gun acceptance matrix

A weapon is done when it passes the whole matrix, not when it fires. The failure this skill
exists to prevent:

```
枪做出来了 ✅   能开火 ✅   能造成伤害 ✅
但枪火飘在枪管旁边 ❌   而且没有任何报错
```

Weapons in this project are data-driven (`resources/weapons/*.tres` +
`scenes/weapons/*.tscn`), so the matrix is driven off the authored list rather than
hardcoded: **anything added to the player's `EquipmentController.loadout` is checked
automatically.**

## The matrix

Run per weapon. ✅ machine-checkable, 👁 needs human eyes.

| # | Check | How |
|---|---|---|
| 1 | `visual_node_name` resolves in the character model | ✅ |
| 2 | `bind_context` produced a non-null `visual_anchor` | ✅ |
| 3 | `weapon_id` set and matching its resource | ✅ |
| 3b | `weapon_id` registered in `GameplayArena.register_weapon_profiles()` | ✅ |
| 4 | `Muzzle` exists and is a `Marker3D` | ✅ |
| 5 | `MuzzleFlash` parented to the muzzle with identity local transform | ✅ |
| 6 | Flash position == ballistic origin fed to the simulation | ✅ |
| 7 | Muzzle aims flat (`forward.y ≈ 0`) to match `WeaponMath.flat_direction` | ✅ |
| 7b | `pellet_count > 1` actually fires a fan of distinct rays, not one line | ✅ |
| 8 | Tracer pool ≥ tracer lifetime × fire rate **× pellet_count** | ✅ |
| 9 | `ShotAudio.max_polyphony` ≥ ceil(sample length × fire rate) | ✅ |
| 10 | Spread values differ from the other weapons (role identity) | ✅ |
| 11 | Bullets-to-kill differs from the other weapons | ✅ |
| 12 | Ammo pressure matches the role | ✅ |
| 13 | Hand grip has no clipping | 👁 |
| 14 | Recoil reads at the intended strength | 👁 |
| 15 | Flash reads as coming *out of* the barrel in motion | 👁 |
| 16 | Weapon swap leaves no stale visual | 👁 |

Checks 1–9 are implemented in `tools/validation/validate_weapon_assembly.gd`. Run it first:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script tools/validation/validate_weapon_assembly.gd
```

## The three checks that catch the most

**#3b — the unregistered weapon.** `register_weapon_profiles()` in `gameplay_arena.gd` holds an
**explicit list** of `RangedWeaponDefinition`s; the index into it is the weapon profile the
simulation resolves damage against. A weapon missing from that list makes
`get_weapon_profile_index()` return `-1`, and `_on_sim_request()` then **silently drops every
shot** — while the muzzle flash and gunshot still play, because those are fired directly by
the presentation layer. The symptom is "the gun raises, it flashes, it makes noise, and it
kills nothing", which reads like a damage-tuning bug and is not one: the shot never entered
the simulation at all. Nothing is logged.

Append new weapons to the **end** of that list. The index is what the simulation stores;
reordering it makes the same bullet resolve against a different profile on a client running
another build.

**#1/#2 — the silent anchor.** `weapon_base.gd` resolves the weapon's visual via
`character_visual_root.find_child(String(definition.visual_node_name))`. A typo or a renamed
model node leaves `visual_anchor` null; `_sync_to_visual_anchor()` then does nothing, and the
weapon — muzzle, flash and ballistic origin with it — sits at the world origin. **Nothing is
logged.** The symptom looks like a physics or camera bug, which is where the debugging time
goes.

**#9 — polyphony vs. fire rate.** Voices below `ceil(sample_length × attacks_per_second)`
means every shot is cut off by the next one. It never sounds like a bug; it sounds like a bad
sound effect, so it gets "fixed" by replacing the sample. Raising the fire rate of an existing
gun silently re-breaks this — which is exactly how it broke here when the SMG went 4 → 10
shots/sec.

## Balance checks the geometry can't see

**Bullets-to-kill (#11).** For every weapon × zombie pair compute
`ceil(zombie.max_health / weapon.damage)`. Two weapons producing the same number against the
baseline zombie **are the same weapon** to the player, whatever their stat sheets say. Current
baseline:

| | 普通(50) | 疾行(30) | 壮硕(260) | sustained DPS |
|---|---|---|---|---|
| 手枪 35 @3/s | 2 | 1 | 8 | 105 |
| 冲锋枪 14 @10/s | 4 | 3 | 19 | 140 |

**Role identity (#10/#12).** A weapon must differ in *how it is used*, not in a damage number.
The dimensions available as pure data on `RangedWeaponDefinition`:

```
damage / attacks_per_second     → time-to-kill and rhythm
trigger_mode                    → semi vs. hold (click pressure)
pellet_count                    → single bullet vs. a fan (see below)
base/max/increase/recovery spread → aim jitter for 1 pellet, fan WIDTH for many
attack_range                    → engagement distance
uses_ammo / max_ammo            → resource pressure
penetration_damage_coefficient  ┐ pierce a line of zombies
max_penetration_count           ┘ (0 on every weapon except where noted)
tracer_pool_size                → presentation capacity, not balance
```

**`pellet_count` changes what `spread` means.** At 1 pellet, spread is aim jitter — a
precision penalty. Above 1, the cone is divided evenly among the pellets and spread becomes
the **width of the fan**, which is what gives a shotgun its range falloff for free: up close
the whole fan lands on one target, far away it opens wider than a zombie and only a couple of
pellets connect. `damage` is always **per pellet**, never the shot total.

**Never combine `pellet_count > 1` with penetration.** Rays per trigger pull become
`pellets × (penetration + 1)`, which multiplies damage and blood-request volume at the same
time — it blows the ground-blood frame budget (see `validate_blood_request_budget`) and makes
the weapon's real damage impossible to reason about. `validate_pellet_spread` enforces this.

## Adding a new weapon

The character model already carries `Knife / Pistol / Rifle / Shotgun / SMG` nodes, so a
rifle or shotgun needs **no new art** — only these steps:

1. `resources/weapons/<id>.tres` — a `RangedWeaponDefinition`; set `visual_node_name` to the
   model node that exists (check the gltf, don't guess).
2. `scenes/weapons/<Name>.tscn` — copy `Smg.tscn`: root with `ranged_weapon.gd`, `Muzzle`
   (`Marker3D`) with `MuzzleFlash` at identity, `ShotAudio` with polyphony sized for the fire
   rate.
3. Add the scene to `EquipmentController.loadout` in `Player.tscn` — this is what puts it into
   the matrix.
4. **Append its definition to `register_weapon_profiles()` in `gameplay_arena.gd`.** Skip this
   and the weapon fires, flashes, and does nothing — see #3b. Append, never insert.
5. `resources/pickups/<id>_pickup.tres` (+ ammo pickup) so it can be acquired.
6. Wire it into the map's `fixed_item_spawns` and/or `zombie_death_rules`.
7. Run `validate_weapon_assembly`, then `validate_automatic_weapon_audio`,
   `validate_equipment_cycle`, `validate_muzzle_flash_orientation`, and
   `validate_ui_font_coverage` (a display name with a level-2 GB2312 glyph such as 霰 renders
   as tofu **only in the Web export**).
8. Check #11 by hand: does it produce a bullets-to-kill number no existing weapon produces?
   If not, it is a reskin — change its role before shipping it.

## Human pass (#13–#16)

Hand over steps, don't ask "please test it":

> 1. `/Applications/Godot.app/Contents/MacOS/Godot --path .`
> 2. Single player → Demo 检查站
> 3. Fire the new weapon while standing still, then while strafing
> 4. Screenshot at the moment of fire — is the flash coming out of the barrel, or beside it?
> 5. Swap to another weapon and back — does the old weapon's visual linger?
> 6. Tell me: does this weapon make you play differently, or is it the previous gun with
>    different numbers?

Step 6 is the one that matters. Everything above it is table stakes.
