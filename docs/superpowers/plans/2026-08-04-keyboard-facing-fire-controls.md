# Keyboard Facing and Forward Fire Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace mouse aiming with keyboard-only controls where WASD determines both camera-relative movement and character facing, Space jumps, and holding J fires the rifle along the character's retained facing direction.

**Architecture:** Keep the fixed orthographic 2.5D camera and existing camera-relative movement calculation, but make the normalized movement direction the single source of truth for player yaw. Remove camera-ray/mouse-plane aiming entirely; the weapon will raycast from the muzzle along the player's Godot-forward `-Z` axis, while the imported character visual receives a 180-degree local correction so the visible gun and functional forward direction agree.

**Tech Stack:** Godot 4.7.1, GDScript, CharacterBody3D, Camera3D orthographic projection, Jolt Physics, native Godot headless test runner.

## Global Constraints

- Execute directly in the current checkout on `main`; create no worktree and no additional branch.
- Preserve Godot `4.7.1.stable.official.a13da4feb`, GL Compatibility rendering, Jolt Physics, the 1280×720 project settings, and `res://scenes/gameplay/DemoArena.tscn` as the sole gameplay entry scene.
- Preserve the existing camera-relative WASD movement because manual acceptance confirmed movement is correct; continue normalizing diagonal input.
- WASD input must immediately determine both travel direction and player facing; releasing all movement keys must retain the most recent facing direction.
- The control scheme must require no mouse input: `W/A/S/D` move and face, `Space` jumps, and holding `J` fires.
- Firing must use the player's current forward direction, remain limited to 6 shots per second, deal 25 damage, use an 80-meter maximum ray, ignore the player body, collide with World + Target layers, and draw the existing muzzle-to-hit tracer.
- Correct the observed 180-degree visual mismatch by keeping the player root's functional forward axis at Godot `-Z` and rotating only `VisualRoot` by 180 degrees around Y.
- Remove obsolete mouse-aim APIs, mouse-plane math, camera injection into the weapon, and left-mouse input binding; do not keep a second hidden aiming mode.
- Preserve grounded-only jumping, animation selection, camera following, arena collision, four static zombie targets, HUD anchoring, target health behavior, and the current deferred roguelite systems.
- Add no external addon or test framework. Run Godot commands through `/Applications/Godot.app/Contents/MacOS/Godot`.

---

## File Structure

- Modify: `project.godot` — replace the `fire` mouse binding with the J key.
- Modify: `tests/unit/test_project_contract.gd` — require J as the sole fire event.
- Modify: `scripts/player/player_motion.gd` — add pure retained-facing yaw calculation.
- Modify: `scripts/player/player_controller.gd` — rename the camera dependency to movement-only and apply facing from movement input.
- Modify: `tests/unit/test_player_motion.gd` — verify forward/right/zero-input facing behavior and diagonal normalization.
- Create: `scripts/combat/weapon_math.gd` — calculate normalized player-forward direction and the exact maximum-range ray endpoint.
- Create: `tests/unit/test_directional_fire.gd` — verify forward-axis conversion, rotated facing, 80-meter endpoint, and fire cadence.
- Delete: `scripts/combat/aim_math.gd` and `scripts/combat/aim_math.gd.uid` — remove mouse-ground-plane intersection logic.
- Delete: `tests/unit/test_aim_and_fire.gd` and `tests/unit/test_aim_and_fire.gd.uid` — replace mouse-aim expectations with directional-fire expectations.
- Modify: `scripts/combat/player_weapon.gd` — fire from the muzzle along player forward without a camera or mouse position.
- Modify: `scenes/player/Player.tscn` — apply the visual 180-degree correction and remove the obsolete aim-plane property.
- Modify: `scripts/gameplay/demo_arena.gd` — inject the camera only for camera-relative movement.
- Modify: `tests/integration/test_demo_scene.gd` — verify on-tree startup wiring, the movement-camera API, and visual correction.
- Modify: `tests/test_runner.gd` — replace the old aim test path with the directional-fire test path.
- Modify: `scenes/gameplay/DemoArena.tscn` — show the keyboard-only controls in the HUD.
- Modify: `README.md` — document keyboard-only movement, facing, jumping, and forward fire.

### Task 1: Replace the fire input contract with J

**Files:**

- Modify: `tests/unit/test_project_contract.gd:4-47`
- Modify: `project.godot:63-68`

**Interfaces:**

- Consumes: the existing `fire` InputMap action read by `PlayerWeapon`.
- Produces: exactly one `InputEventKey` for `fire`, with `keycode == KEY_J`.

- [ ] **Step 1: Write the failing J-binding contract**

Replace `REQUIRED_KEY_BINDINGS` and the action-event loop in `tests/unit/test_project_contract.gd` with:

```gdscript
const REQUIRED_KEY_BINDINGS: Dictionary = {
	&"move_left": KEY_A,
	&"move_right": KEY_D,
	&"move_forward": KEY_W,
	&"move_back": KEY_S,
	&"jump": KEY_SPACE,
	&"fire": KEY_J,
}

func run() -> Array[String]:
	var failures: Array[String] = []
	var version := Engine.get_version_info()
	_append(failures, Assertions.expect_equal(version["major"], 4, "Godot major version"))
	_append(failures, Assertions.expect_equal(version["minor"], 7, "Godot minor version"))
	_append(failures, Assertions.expect_equal(version["patch"], 1, "Godot patch version"))
	_append(failures, Assertions.expect_equal(
		ProjectSettings.get_setting("physics/3d/physics_engine"),
		"Jolt Physics",
		"3D physics engine"
	))
	for action in REQUIRED_ACTIONS:
		_append(failures, Assertions.expect_true(InputMap.has_action(action), "Missing input action: %s" % action))
		if not InputMap.has_action(action):
			continue
		var events := InputMap.action_get_events(action)
		_append(failures, Assertions.expect_equal(events.size(), 1, "Input event count for %s" % action))
		if events.size() != 1:
			continue
		var event := events[0]
		_append(failures, Assertions.expect_true(event is InputEventKey, "Input binding is a key: %s" % action))
		if event is InputEventKey:
			_append(failures, Assertions.expect_equal(event.keycode, REQUIRED_KEY_BINDINGS[action], "Key binding for %s" % action))
	return failures
```

- [ ] **Step 2: Run the contract test and verify RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1`; `test_project_contract.gd` reports `Input binding is a key: fire` because `fire` is still left mouse.

- [ ] **Step 3: Replace the mouse event with the J key**

Replace the `[input]` `fire` block in `project.godot` with:

```ini
fire={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":74,"physical_keycode":0,"key_label":0,"unicode":106,"location":0,"echo":false,"script":null)
]
}
```

- [ ] **Step 4: Run the complete suite and verify GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `0` and `PASS: 6 test file(s)`.

- [ ] **Step 5: Commit the keyboard fire binding**

```bash
git add project.godot tests/unit/test_project_contract.gd
git commit -m "feat: bind keyboard fire control"
```

### Task 2: Make movement direction drive facing and forward fire

**Files:**

- Modify: `tests/unit/test_player_motion.gd`
- Create: `tests/unit/test_directional_fire.gd`
- Modify: `tests/test_runner.gd`
- Modify: `tests/integration/test_demo_scene.gd`
- Modify: `scripts/player/player_motion.gd`
- Modify: `scripts/player/player_controller.gd`
- Create: `scripts/combat/weapon_math.gd`
- Modify: `scripts/combat/player_weapon.gd`
- Modify: `scenes/player/Player.tscn`
- Modify: `scripts/gameplay/demo_arena.gd`
- Delete: `scripts/combat/aim_math.gd`
- Delete: `scripts/combat/aim_math.gd.uid`
- Delete: `tests/unit/test_aim_and_fire.gd`
- Delete: `tests/unit/test_aim_and_fire.gd.uid`

**Interfaces:**

- Consumes: `PlayerMotion.world_direction(input_vector: Vector2, camera_basis: Basis) -> Vector3`, `FireGate.tick(delta: float) -> void`, `FireGate.try_consume() -> bool`, `FollowCamera.set_target(value: Node3D) -> void`, and `Player/Weapon/Muzzle`.
- Produces: `PlayerMotion.next_facing_yaw(direction: Vector3, current_yaw: float) -> float`, `PlayerController.set_movement_camera(camera: Camera3D) -> void`, `WeaponMath.forward_direction(player_basis: Basis) -> Vector3`, and `WeaponMath.ray_end(origin: Vector3, player_basis: Basis, max_range: float) -> Vector3`.

- [ ] **Step 1: Extend the movement test with retained-facing expectations**

Add this guarded method contract after the existing diagonal-normalization assertion in `tests/unit/test_player_motion.gd`:

```gdscript
	var has_facing_yaw := false
	for method: Dictionary in player_motion.get_script_method_list():
		if method.get("name", "") == "next_facing_yaw":
			has_facing_yaw = true
			break
	_append(failures, Assertions.expect_true(
		has_facing_yaw,
		"PlayerMotion exposes retained-facing yaw"
	))
	if has_facing_yaw:
		var forward_yaw: float = player_motion.next_facing_yaw(expected_forward, 0.75)
		var forward_after_yaw := -Basis(Vector3.UP, forward_yaw).z
		_append(failures, Assertions.expect_vector3_near(
			forward_after_yaw,
			expected_forward,
			0.0001,
			"Movement direction determines player forward"
		))

		var right_yaw: float = player_motion.next_facing_yaw(Vector3.RIGHT, 0.0)
		var right_after_yaw := -Basis(Vector3.UP, right_yaw).z
		_append(failures, Assertions.expect_vector3_near(
			right_after_yaw,
			Vector3.RIGHT,
			0.0001,
			"Right movement faces right"
		))

		_append(failures, Assertions.expect_float_near(
			player_motion.next_facing_yaw(Vector3.ZERO, 0.75),
			0.75,
			0.0001,
			"No movement retains the previous facing"
		))
```

- [ ] **Step 2: Replace the mouse-aim unit test with a failing directional-fire test**

Create `tests/unit/test_directional_fire.gd`:

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const WEAPON_MATH_PATH := "res://scripts/combat/weapon_math.gd"
const FIRE_GATE_PATH := "res://scripts/combat/fire_gate.gd"

func run() -> Array[String]:
	var failures: Array[String] = []
	var weapon_math := load(WEAPON_MATH_PATH) as Script
	var fire_gate_script := load(FIRE_GATE_PATH) as Script
	_append(failures, Assertions.expect_true(weapon_math != null, "Weapon math helper loads"))
	_append(failures, Assertions.expect_true(fire_gate_script != null, "Fire gate helper loads"))

	if weapon_math != null:
		_append(failures, Assertions.expect_vector3_near(
			weapon_math.forward_direction(Basis.IDENTITY),
			Vector3.FORWARD,
			0.0001,
			"Identity player basis fires along Godot forward"
		))
		var right_facing_basis := Basis(Vector3.UP, -PI / 2.0)
		_append(failures, Assertions.expect_vector3_near(
			weapon_math.forward_direction(right_facing_basis),
			Vector3.RIGHT,
			0.0001,
			"Rotated player fires along retained facing"
		))
		_append(failures, Assertions.expect_vector3_near(
			weapon_math.ray_end(Vector3(1.0, 1.2, 1.0), right_facing_basis, 80.0),
			Vector3(81.0, 1.2, 1.0),
			0.0001,
			"Directional ray keeps the 80 meter range"
		))

	if fire_gate_script != null:
		var gate: RefCounted = fire_gate_script.new(1.0 / 6.0) as RefCounted
		_append(failures, Assertions.expect_true(gate.call("try_consume"), "First shot is immediately available"))
		_append(failures, Assertions.expect_true(not gate.call("try_consume"), "Second immediate shot is blocked"))
		gate.call("tick", 1.0 / 6.0)
		_append(failures, Assertions.expect_true(gate.call("try_consume"), "Shot is available after cooldown"))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

Replace the old aim-test path in `tests/test_runner.gd`:

```gdscript
	"res://tests/unit/test_directional_fire.gd",
```

- [ ] **Step 3: Strengthen the scene test for movement-camera wiring and visual orientation**

Replace `run()` in `tests/integration/test_demo_scene.gd` with:

```gdscript
func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
	_append(failures, Assertions.expect_true(packed != null, "Demo arena scene loads"))
	if packed == null:
		return failures

	var arena := packed.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(arena)

	var player := arena.get_node_or_null("Player")
	var visual_root := arena.get_node_or_null("Player/VisualRoot") as Node3D
	var follow_camera := arena.get_node_or_null("FollowCamera") as FollowCamera
	var camera := arena.get_node_or_null("FollowCamera/Camera3D") as Camera3D
	var targets := arena.get_node_or_null("World/Targets")
	_append(failures, Assertions.expect_true(player != null, "Demo has Player"))
	_append(failures, Assertions.expect_true(
		player != null and player.has_method("set_movement_camera"),
		"Player accepts movement camera"
	))
	if player != null and player.has_method("set_movement_camera"):
		_append(failures, Assertions.expect_true(
			player.get("movement_camera") == camera,
			"Demo wires camera-relative movement on startup"
		))
	_append(failures, Assertions.expect_true(
		follow_camera != null and follow_camera.target == player,
		"Demo wires camera follow on startup"
	))
	_append(failures, Assertions.expect_true(visual_root != null, "Player has VisualRoot"))
	if visual_root != null:
		_append(failures, Assertions.expect_float_near(
			absf(visual_root.rotation.y),
			PI,
			0.0001,
			"Player visual is corrected by 180 degrees"
		))
	_append(failures, Assertions.expect_true(camera != null, "Demo has Camera3D"))
	if camera != null:
		_append(failures, Assertions.expect_equal(camera.projection, Camera3D.PROJECTION_ORTHOGONAL, "Camera is orthographic"))
		_append(failures, Assertions.expect_float_near(camera.size, 18.0, 0.0001, "Camera orthographic size"))
	_append(failures, Assertions.expect_true(targets != null and targets.get_child_count() == 4, "Demo has four zombie targets"))
	var configured_main_scene: String = ProjectSettings.get_setting("application/run/main_scene", "")
	var resolved_main_scene := configured_main_scene
	if configured_main_scene.begins_with("uid://"):
		resolved_main_scene = ResourceUID.get_id_path(ResourceUID.text_to_id(configured_main_scene))
	_append(failures, Assertions.expect_equal(resolved_main_scene, "res://scenes/gameplay/DemoArena.tscn", "Demo arena is project main scene"))
	arena.free()
	return failures
```

- [ ] **Step 4: Run the new behavior tests and verify RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1` with failures for `PlayerMotion exposes retained-facing yaw`, `Weapon math helper loads`, `Player accepts movement camera`, and `Player visual is corrected by 180 degrees`.

- [ ] **Step 5: Implement retained-facing yaw as pure movement logic**

Add to `scripts/player/player_motion.gd` after `world_direction()`:

```gdscript
static func next_facing_yaw(direction: Vector3, current_yaw: float) -> float:
	var flat_direction := Vector3(direction.x, 0.0, direction.z)
	if flat_direction.length_squared() <= 0.0001:
		return current_yaw
	flat_direction = flat_direction.normalized()
	return atan2(-flat_direction.x, -flat_direction.z)
```

Replace `scripts/player/player_controller.gd` with:

```gdscript
extends CharacterBody3D
class_name PlayerController

const PlayerMotion = preload("res://scripts/player/player_motion.gd")
const HIDDEN_WEAPONS: Array[String] = [
	"Axe", "Guitar", "Knife", "Pistol", "Shotgun", "SMG", "Spear",
	"WoodenBat_Barbed", "WoodenBat_Saw",
]

@export var move_speed: float = 6.0
@export var ground_acceleration: float = 30.0
@export var air_acceleration: float = 12.0
@export var gravity: float = 24.0
@export var jump_speed: float = 8.5

@onready var visual_root: Node3D = $VisualRoot

var movement_camera: Camera3D
var animation_player: AnimationPlayer

func _ready() -> void:
	animation_player = visual_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	for weapon_name in HIDDEN_WEAPONS:
		var weapon_visual := visual_root.find_child(weapon_name, true, false) as Node3D
		if weapon_visual != null:
			weapon_visual.visible = false

func set_movement_camera(camera: Camera3D) -> void:
	movement_camera = camera

func _physics_process(delta: float) -> void:
	var input_vector := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var camera_basis := movement_camera.global_basis if movement_camera != null else Basis.IDENTITY
	var direction := PlayerMotion.world_direction(input_vector, camera_basis)
	rotation.y = PlayerMotion.next_facing_yaw(direction, rotation.y)
	var target_velocity := direction * move_speed
	var acceleration := ground_acceleration if is_on_floor() else air_acceleration

	velocity.x = move_toward(velocity.x, target_velocity.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, target_velocity.z, acceleration * delta)
	velocity.y = PlayerMotion.next_vertical_velocity(
		velocity.y,
		is_on_floor(),
		Input.is_action_just_pressed("jump"),
		delta,
		gravity,
		jump_speed
	)
	move_and_slide()
	_update_animation(Vector2(velocity.x, velocity.z).length())

func _update_animation(horizontal_speed: float) -> void:
	if animation_player == null:
		return
	var animation_name := &"Idle_Gun"
	if not is_on_floor():
		animation_name = &"Jump_Idle"
	elif horizontal_speed > 0.2:
		animation_name = &"Run_Gun"
	if animation_player.current_animation != animation_name:
		animation_player.play(animation_name, 0.15)
```

- [ ] **Step 6: Implement player-forward weapon math**

Create `scripts/combat/weapon_math.gd`:

```gdscript
extends RefCounted
class_name WeaponMath

static func forward_direction(player_basis: Basis) -> Vector3:
	var direction := -player_basis.z
	direction.y = 0.0
	return direction.normalized()

static func ray_end(origin: Vector3, player_basis: Basis, max_range: float) -> Vector3:
	return origin + forward_direction(player_basis) * maxf(max_range, 0.0)
```

Replace `scripts/combat/player_weapon.gd` with:

```gdscript
extends Node3D
class_name PlayerWeapon

const WeaponMath = preload("res://scripts/combat/weapon_math.gd")
const FireGate = preload("res://scripts/combat/fire_gate.gd")
const TRACER_SCENE := preload("res://scenes/fx/ShotTracer.tscn")

@export var shots_per_second: float = 6.0
@export var damage: float = 25.0
@export var max_range: float = 80.0
@export_flags_3d_physics var hit_collision_mask: int = 5

@onready var muzzle: Marker3D = $Muzzle

var fire_gate: FireGate

func _ready() -> void:
	fire_gate = FireGate.new(1.0 / shots_per_second)

func _physics_process(delta: float) -> void:
	fire_gate.tick(delta)
	var player := get_parent() as PlayerController
	if player == null:
		return
	if Input.is_action_pressed("fire") and fire_gate.try_consume():
		_fire(player)

func _fire(player: PlayerController) -> void:
	var ray_origin := muzzle.global_position
	var ray_direction := WeaponMath.forward_direction(player.global_basis)
	var ray_end := WeaponMath.ray_end(ray_origin, player.global_basis, max_range)
	var query := PhysicsRayQueryParameters3D.create(
		ray_origin,
		ray_end,
		hit_collision_mask,
		[player.get_rid()]
	)
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	var hit_position: Vector3 = result.get("position", ray_end)
	var collider: Object = result.get("collider", null)
	if collider != null and collider.has_method("apply_damage"):
		collider.call("apply_damage", damage, hit_position)

	var tracer := TRACER_SCENE.instantiate() as ShotTracer
	get_tree().current_scene.add_child(tracer)
	tracer.setup(ray_origin, hit_position)
```

- [ ] **Step 7: Remove mouse-aim files and update scene configuration**

Delete the obsolete source and test files:

```bash
git rm scripts/combat/aim_math.gd scripts/combat/aim_math.gd.uid
git rm tests/unit/test_aim_and_fire.gd tests/unit/test_aim_and_fire.gd.uid
```

Update `scenes/player/Player.tscn` to use these exact node properties:

```ini
[node name="VisualRoot" type="Node3D" parent="."]
rotation_degrees = Vector3(0, 180, 0)

[node name="Weapon" type="Node3D" parent="."]
position = Vector3(0, 1.2, -0.35)
script = ExtResource("3_weapon")
shots_per_second = 6.0
damage = 25.0
max_range = 80.0
hit_collision_mask = 5

[node name="Muzzle" type="Marker3D" parent="Weapon"]
position = Vector3(0, 0, -0.9)
```

This removes `aim_plane_y`, keeps the muzzle on functional `-Z`, and rotates only the imported visual so the visible rifle points along the ray.

- [ ] **Step 8: Rename the arena camera wiring to movement-only**

Replace `scripts/gameplay/demo_arena.gd` with:

```gdscript
extends Node3D

@onready var player: PlayerController = $Player
@onready var follow_camera: FollowCamera = $FollowCamera
@onready var movement_camera: Camera3D = $FollowCamera/Camera3D

func _ready() -> void:
	follow_camera.set_target(player)
	player.set_movement_camera(movement_camera)
```

- [ ] **Step 9: Import, run all tests, and verify GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit-after 3
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
git diff --check
```

Expected: no missing-script or parser errors, exit code `0`, `PASS: 6 test file(s)`, and no whitespace errors. Godot should generate `scripts/combat/weapon_math.gd.uid` and `tests/unit/test_directional_fire.gd.uid`; stage both generated sidecars.

- [ ] **Step 10: Run the focused live control check**

Launch:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

Verify:

```text
W/A/S/D: player movement remains camera-relative and diagonal speed remains normalized
Facing: visible body and gun immediately point in the movement direction
Release: player stops but keeps the last facing direction
Mouse movement: has no effect on player facing or shot direction
Hold J: tracers leave the muzzle along retained facing at no more than 6 shots per second
Target: a target directly in the retained facing changes 50 / 50 -> 25 / 50 -> DOWN after two shots
```

- [ ] **Step 11: Commit directional facing and forward fire**

```bash
git add scripts/player scripts/combat scripts/gameplay scenes/player tests/unit tests/integration tests/test_runner.gd
git commit -m "feat: fire along keyboard-controlled facing"
```

### Task 3: Update keyboard-only guidance and complete acceptance

**Files:**

- Modify: `tests/integration/test_demo_scene.gd`
- Modify: `scenes/gameplay/DemoArena.tscn:198-213`
- Modify: `README.md:13-18`

**Interfaces:**

- Consumes: the final input contract and directional player/weapon behavior from Tasks 1 and 2.
- Produces: exact in-game and README guidance for `WASD MOVE + FACE`, `SPACE JUMP`, and `J FIRE`, plus final manual acceptance evidence.

- [ ] **Step 1: Write the failing HUD contract**

In `tests/integration/test_demo_scene.gd`, retrieve the controls label with the other scene nodes:

```gdscript
	var controls := arena.get_node_or_null("HUD/ControlsPanel/Controls") as Label
```

Add this assertion before freeing the arena:

```gdscript
	_append(failures, Assertions.expect_true(controls != null, "Demo has controls label"))
	if controls != null:
		_append(failures, Assertions.expect_equal(
			controls.text,
			"WASD  MOVE + FACE    SPACE  JUMP    J  FIRE",
			"HUD documents keyboard-only controls"
		))
```

- [ ] **Step 2: Run the integration contract and verify RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1` with `HUD documents keyboard-only controls`; the current HUD still says `LMB FIRE`.

- [ ] **Step 3: Update the in-game controls panel**

Set the controls label in `scenes/gameplay/DemoArena.tscn` to:

```ini
[node name="Controls" type="Label" parent="HUD/ControlsPanel"]
layout_mode = 2
theme_override_colors/font_color = Color(0.952941, 0.933333, 0.894118, 1)
theme_override_font_sizes/font_size = 16
text = "WASD  MOVE + FACE    SPACE  JUMP    J  FIRE"
```

- [ ] **Step 4: Replace README control guidance**

Replace the `## Controls` section in `README.md` with:

```markdown
## Controls

- `W/A/S/D`: camera-relative movement and facing
- Release movement keys: retain the last facing direction
- `Space`: grounded jump
- Hold `J`: fire the rifle along the current facing direction

Mouse input is not used by the demo.
```

Leave the run command, scope, deferred systems, and test command unchanged.

- [ ] **Step 5: Run final automated verification**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit-after 3
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
git diff --check
```

Expected: clean import/parse, exit code `0`, `PASS: 6 test file(s)`, and no whitespace errors.

- [ ] **Step 6: Perform the final keyboard-only acceptance matrix**

Run the main scene and record every row:

| Requirement | Verification | Expected result |
| --- | --- | --- |
| 2.5D view | Move throughout the arena | Orthographic fixed-angle presentation remains unchanged |
| Cardinal facing | Tap W, A, S, and D separately | Body and visible rifle face the same camera-relative direction as movement |
| Diagonal facing | Hold W+D | Travel speed stays normalized and facing follows the diagonal |
| Retained facing | Release all movement keys | Player stops and retains the last facing direction |
| Mouse removal | Move and click the mouse | Mouse does not rotate the player or fire the rifle |
| Jump | Tap Space on ground and again in air | Grounded input jumps; airborne input does not double-jump |
| Forward fire | Face a target and hold J | Tracers travel from the muzzle along retained facing at 6 shots per second |
| Damage | Shoot one target twice | Label changes `50 / 50` -> `25 / 50` -> `DOWN`, then target disappears |
| Collision | Walk into boundaries, pickup, and containers | Player remains blocked by collision geometry |
| Camera | Move and jump near arena edges | Follow remains smooth; rotation and orthographic size do not change |
| Resize | Resize from 1280×720 | HUD remains anchored and playable area remains visible |
| Runtime health | Play for two minutes while observing output | No parser errors, invalid calls, missing resources, or repeated new warnings |

- [ ] **Step 7: Commit the keyboard-only guidance**

```bash
git add README.md scenes/gameplay/DemoArena.tscn tests/integration/test_demo_scene.gd
git commit -m "docs: describe keyboard-only combat controls"
```

## Self-Review

1. **Spec coverage:** Task 1 removes the last-mouse fire binding and assigns J. Task 2 makes movement input control and retain facing, corrects the 180-degree visual orientation, removes mouse aiming, fires from the muzzle along player forward, preserves cadence/damage/range, and updates startup wiring. Task 3 updates both user-facing control surfaces and requires a keyboard-only acceptance pass.
2. **Placeholder scan:** The plan contains exact paths, signatures, test bodies, production code, property values, commands, expected failures, expected successes, commit boundaries, and acceptance rows; no unresolved implementation choice remains.
3. **Type consistency:** `DemoArena` calls `PlayerController.set_movement_camera(Camera3D)`; `PlayerController` stores `movement_camera: Camera3D`; `PlayerMotion.next_facing_yaw(Vector3, float)` returns the player root yaw; `PlayerWeapon` passes `player.global_basis` to both `WeaponMath` functions; the test runner references exactly `test_directional_fire.gd`; the HUD and README use the confirmed J binding.
