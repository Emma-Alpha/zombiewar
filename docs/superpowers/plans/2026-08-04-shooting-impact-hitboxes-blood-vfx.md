# Shooting Impact, Hitboxes, and Blood VFX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make shots easier to connect, give each zombie body region a distinct damage/knockback response, and spawn readable blood impact effects.

**Architecture:** Replace the single static target collider with a `CharacterBody3D` that owns one movement collider and several ray-queryable `Area3D` hitboxes. Each hitbox forwards a typed hit response to the zombie; deterministic hit-response math produces the impulse while the target applies gravity, damping, collision-aware movement, and springy visual recoil. A short-lived `BloodImpact` scene combines a CC0 Kenney splat sprite with directional Godot particles.

**Tech Stack:** Godot 4.7.1, GDScript, Jolt Physics, Kenney Splat Pack (CC0).

## Global Constraints

- Preserve the existing dirty-worktree changes for tracer pooling and physics interpolation.
- Keep weapon compatibility with colliders that only implement `apply_damage`.
- Use collision layer 4 for damageable hitboxes and layer 1 for arena geometry.
- Do not add a third-party runtime plugin or physics dependency.
- Record every imported external asset and its license in the repository.
- Do not create a git commit automatically while unrelated user changes remain in the worktree.

---

### Task 1: Deterministic Hit Response Math

**Files:**
- Create: `scripts/combat/hit_response_math.gd`
- Create: `tests/unit/test_hit_response_math.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Produces: `HitResponseMath.knockback_velocity(shot_direction: Vector3, impulse: float, multiplier: float, vertical_bias: float) -> Vector3`

- [ ] **Step 1: Write the failing test**

```gdscript
var torso := HitResponseMath.knockback_velocity(Vector3(1, 0, 0), 6.0, 1.0, 0.05)
var head := HitResponseMath.knockback_velocity(Vector3(1, 0, 0), 6.0, 1.35, 0.22)
_append(failures, Assertions.expect_true(head.x > torso.x, "Head hit has stronger horizontal impulse"))
_append(failures, Assertions.expect_true(head.y > torso.y, "Head hit has stronger lift"))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tests/test_runner.gd`

Expected: FAIL because `res://scripts/combat/hit_response_math.gd` does not exist.

- [ ] **Step 3: Write minimal implementation**

```gdscript
static func knockback_velocity(shot_direction: Vector3, impulse: float, multiplier: float, vertical_bias: float) -> Vector3:
	var planar := Vector3(shot_direction.x, 0.0, shot_direction.z)
	if planar.length_squared() <= 0.000001:
		planar = Vector3.FORWARD
	planar = planar.normalized()
	var strength := maxf(impulse, 0.0) * maxf(multiplier, 0.0)
	return planar * strength + Vector3.UP * maxf(impulse, 0.0) * maxf(vertical_bias, 0.0)
```

- [ ] **Step 4: Run test to verify it passes**

Run the full headless test command and expect the new unit test to pass.

### Task 2: Multi-region Zombie Hitboxes and Physics Knockback

**Files:**
- Create: `scripts/combat/zombie_hitbox.gd`
- Create: `tests/unit/test_zombie_hitboxes.gd`
- Modify: `scripts/combat/zombie_target.gd`
- Modify: `scenes/targets/ZombieTarget.tscn`
- Modify: `scripts/combat/player_weapon.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: `HitResponseMath.knockback_velocity(...)`
- Produces: `ZombieHitbox.apply_hit(amount: float, hit_position: Vector3, shot_direction: Vector3) -> void`
- Produces: `ZombieTarget.apply_hit(amount: float, hit_position: Vector3, shot_direction: Vector3, hit_zone: StringName, damage_multiplier: float, knockback_multiplier: float, vertical_bias: float) -> void`

- [ ] **Step 1: Write the failing hitbox scene test**

```gdscript
var zombie := ZOMBIE_SCENE.instantiate() as CharacterBody3D
var hitboxes := zombie.get_node("Hitboxes").get_children()
_append(failures, Assertions.expect_true(hitboxes.size() >= 5, "Zombie exposes forgiving body-region hitboxes"))
for hitbox in hitboxes:
	_append(failures, Assertions.expect_equal(hitbox.collision_layer, 4, "%s is ray-queryable" % hitbox.name))
```

- [ ] **Step 2: Run test to verify it fails**

Run the full headless test command and expect failure because the current target is a `StaticBody3D` with one capsule collider.

- [ ] **Step 3: Implement region forwarding and collision-aware movement**

```gdscript
func apply_hit(amount: float, hit_position: Vector3, shot_direction: Vector3) -> void:
	var target := get_parent().get_parent()
	target.apply_hit(amount, hit_position, shot_direction, hit_zone, damage_multiplier, knockback_multiplier, vertical_bias)
```

The scene will contain head, torso, left-side, right-side, and legs hitboxes with larger overlapping shapes. The target will accumulate velocity, call `move_and_slide()`, apply gravity and planar drag, and spring the visual root back from a force/lever-arm tilt.

- [ ] **Step 4: Update weapon delivery**

```gdscript
query.collide_with_areas = true
if collider != null and collider.has_method("apply_hit"):
	collider.call("apply_hit", damage, hit_position, ray_direction)
elif collider != null and collider.has_method("apply_damage"):
	collider.call("apply_damage", damage, hit_position)
```

- [ ] **Step 5: Run tests to verify they pass**

Run the full headless suite and expect the math, scene, health, weapon, and integration contracts to remain green.

### Task 3: Blood Impact Sprite and Directional Droplets

**Files:**
- Copy: `assets/fx/blood/kenney_splat29.png`
- Create: `assets/fx/blood/License.txt`
- Create: `scripts/fx/blood_impact.gd`
- Create: `scenes/fx/BloodImpact.tscn`
- Create: `tests/unit/test_blood_impact.gd`
- Modify: `scripts/combat/zombie_target.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Produces: `BloodImpact.setup(hit_position: Vector3, shot_direction: Vector3, intensity: float = 1.0) -> void`
- Consumed by: `ZombieTarget.apply_hit(...)`

- [ ] **Step 1: Write the failing VFX scene test**

```gdscript
var effect := BLOOD_IMPACT_SCENE.instantiate() as Node3D
_append(failures, Assertions.expect_true(effect.get_node_or_null("Splat") is Sprite3D, "Blood impact has a splat sprite"))
_append(failures, Assertions.expect_true(effect.get_node_or_null("Droplets") is GPUParticles3D, "Blood impact has directional droplets"))
```

- [ ] **Step 2: Run test to verify it fails**

Run the full headless suite and expect failure because `BloodImpact.tscn` does not exist.

- [ ] **Step 3: Import the CC0 texture and implement the effect**

The `Sprite3D` uses `kenney_splat29.png`, tinted dark red and expanded/faded over approximately 0.45 seconds. `GPUParticles3D` emits a one-shot burst of red droplets along the shot direction with gravity.

- [ ] **Step 4: Spawn the effect for every successful zombie hit**

```gdscript
var blood := BLOOD_IMPACT_SCENE.instantiate() as BloodImpact
get_parent().add_child(blood)
blood.setup(hit_position, shot_direction, knockback_multiplier)
```

- [ ] **Step 5: Run tests to verify they pass**

Run the full headless suite and expect all tests to pass with no parse errors or warnings.

### Task 4: Runtime Verification and Asset Documentation

**Files:**
- Modify: `README.md`
- Create: `docs/assets/shooting-impact-assets.md`

**Interfaces:**
- Documents: source URLs, CC0 status, selected asset, and rejected alternatives.

- [ ] **Step 1: Run the complete test suite**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tests/test_runner.gd`

Expected: exit code 0 and `PASS`.

- [ ] **Step 2: Launch the demo and inspect runtime output**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --path . --editor project.godot`

Verify shots connect across the wider silhouette, head/torso/limb hits move the zombie differently, blood effects face the camera and emit away from the muzzle, and knocked targets remain constrained by arena collisions.

- [ ] **Step 3: Record asset findings**

Document Kenney Splat Pack as the integrated CC0 source; document Quaternius Zombie Apocalypse Kit and Toon Shooter Game Kit as CC0 alternatives; record that Poly Haven returned zero results for `blood` and is better suited to CC0 environment materials.

## Self-Review

- Spec coverage: Task 2 covers multi-direction hitboxes and region-dependent knockback; Task 3 covers blood effects; Task 4 covers the requested marketplace review.
- Placeholder scan: no deferred implementation placeholders remain.
- Type consistency: hitbox forwarding, target hit handling, and effect setup signatures match across all tasks.
