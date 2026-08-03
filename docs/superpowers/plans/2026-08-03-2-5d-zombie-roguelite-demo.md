# 2.5D Zombie Roguelite Playable Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one runnable 2.5D zombie-game demo scene in which the player can move, jump, aim with the mouse, and fire a rifle at static zombie targets.

**Architecture:** Use a full 3D Godot world with movement constrained to the XZ ground plane and a fixed-angle orthographic camera to create the 2.5D view. Keep movement, camera following, aiming/fire cadence, health, visual effects, and scene wiring in focused scripts with pure calculation helpers covered by headless tests. The first milestone proves the player-control foundation for a future roguelite loop; enemy AI, spawning waves, upgrades, loot, and run progression remain outside this demo.

**Tech Stack:** Godot 4.7.1, GDScript, CharacterBody3D, Jolt Physics, Camera3D orthographic projection, native Godot headless test runner, supplied CC0 Quaternius assets.

## Global Constraints

- Use the existing Godot `4.7.1.stable.official.a13da4feb` project and preserve the GL Compatibility renderer plus Jolt Physics settings.
- Present the world from a fixed-angle orthographic 2.5D camera; gameplay remains physically 3D.
- Deliver exactly one runnable gameplay entry scene at `res://scenes/gameplay/DemoArena.tscn`.
- The player must support WASD movement, Space jump, mouse aiming, and left-mouse continuous fire.
- Movement is camera-relative on the XZ plane, diagonal input is normalized, and jumping is allowed only while grounded.
- Shooting uses a camera ray for cursor accuracy, a visible muzzle-to-hit tracer, a rate limit of 6 shots per second, 25 damage per shot, and an 80-meter maximum range.
- Include static zombie targets only to verify gun damage; do not add enemy navigation, attacks, procedural waves, experience, upgrades, loot, or run persistence in this milestone.
- Preserve `docs/game_resources_zombie_prototype/` as the source archive and copy only the exact assets used by the demo into `res://assets/`.
- Use only bundled Godot features and supplied CC0 assets; add no external addons or test frameworks.
- Run automated checks through `/Applications/Godot.app/Contents/MacOS/Godot` because `godot` is not currently on the shell `PATH`.

---

## File Structure

- Modify: `project.godot` — configure the window, named physics layers, controls, and gameplay main scene.
- Create: `tests/helpers/assertions.gd` — minimal assertion helpers shared by headless tests.
- Create: `tests/test_runner.gd` — loads each test script and exits Godot with a reliable status code.
- Create: `tests/unit/test_project_contract.gd` — verifies Godot version assumptions and required input actions.
- Create: `tests/unit/test_player_motion.gd` — verifies camera-relative movement, diagonal normalization, gravity, and grounded jump rules.
- Create: `tests/unit/test_follow_camera.gd` — verifies frame-rate-independent camera smoothing weights.
- Create: `tests/unit/test_aim_and_fire.gd` — verifies mouse-ray plane intersection and weapon cadence.
- Create: `tests/unit/test_health.gd` — verifies target damage, clamping, and depletion behavior.
- Create: `tests/integration/test_demo_scene.gd` — verifies the final scene hierarchy, orthographic camera, targets, and project entry point.
- Create: `scripts/player/player_motion.gd` — pure movement and vertical-velocity calculations.
- Create: `scripts/player/player_controller.gd` — CharacterBody3D input, movement, jump, facing, and imported animation selection.
- Create: `scripts/camera/follow_camera.gd` — smooth XZ tracking while preserving the fixed 2.5D camera height and angle.
- Create: `scripts/combat/aim_math.gd` — pure ray/ground-plane intersection.
- Create: `scripts/combat/fire_gate.gd` — deterministic fire-rate cooldown.
- Create: `scripts/combat/player_weapon.gd` — mouse aiming, physics ray query, target damage, and tracer spawning.
- Create: `scripts/combat/health.gd` — reusable numeric health state.
- Create: `scripts/combat/zombie_target.gd` — binds health to a static zombie target scene.
- Create: `scripts/fx/shot_tracer.gd` — short-lived emissive hitscan line.
- Create: `scripts/gameplay/demo_arena.gd` — wires the player to the camera when the demo starts.
- Create: `scenes/player/Player.tscn` — player body, capsule collision, imported visual, weapon pivot, and muzzle.
- Create: `scenes/camera/FollowCamera.tscn` — camera rig plus orthographic Camera3D.
- Create: `scenes/fx/ShotTracer.tscn` — reusable tracer effect scene.
- Create: `scenes/targets/ZombieTarget.tscn` — static damageable target using the supplied basic-zombie model.
- Create: `scenes/gameplay/DemoArena.tscn` — lit arena, collisions, props, player, camera, targets, and controls HUD.
- Copy: `assets/characters/Characters_Lis_SingleWeapon.gltf` and `assets/characters/Characters_Lis_SingleWeapon_Zombie_Atlas.png` — player visual and atlas.
- Copy: `assets/enemies/Zombie_Basic.gltf` and `assets/enemies/Zombie_Basic_Zombie_Atlas.png` — zombie target visual and atlas.
- Copy: `assets/environment/Container_Red.gltf` and `assets/environment/Container_Red_Zombie_Atlas.png` — arena cover visual.
- Copy: `assets/vehicles/Vehicle_Pickup.gltf` and `assets/vehicles/Vehicle_Pickup_Zombie_Atlas.png` — arena landmark visual.
- Create: `README.md` — run instructions, controls, verified scope, and deferred roguelite systems.

### Task 1: Establish the project contract and headless test runner

**Files:**
- Modify: `project.godot`
- Create: `tests/helpers/assertions.gd`
- Create: `tests/test_runner.gd`
- Create: `tests/unit/test_project_contract.gd`

**Interfaces:**
- Consumes: Godot `Engine`, `InputMap`, and the existing `project.godot` settings.
- Produces: `Assertions.expect_true(condition: bool, message: String) -> String`, `Assertions.expect_equal(actual: Variant, expected: Variant, message: String) -> String`, a headless test command, and the input actions `move_left`, `move_right`, `move_forward`, `move_back`, `jump`, and `fire`.

- [ ] **Step 1: Create the assertion helper and failing project-contract test**

Create `tests/helpers/assertions.gd`:

```gdscript
extends RefCounted
class_name Assertions

static func expect_true(condition: bool, message: String) -> String:
    return "" if condition else message

static func expect_equal(actual: Variant, expected: Variant, message: String) -> String:
    if actual == expected:
        return ""
    return "%s — expected %s, got %s" % [message, str(expected), str(actual)]

static func expect_float_near(actual: float, expected: float, tolerance: float, message: String) -> String:
    if absf(actual - expected) <= tolerance:
        return ""
    return "%s — expected %.4f, got %.4f" % [message, expected, actual]

static func expect_vector3_near(actual: Vector3, expected: Vector3, tolerance: float, message: String) -> String:
    if actual.distance_to(expected) <= tolerance:
        return ""
    return "%s — expected %s, got %s" % [message, str(expected), str(actual)]
```

Create `tests/unit/test_project_contract.gd`:

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const REQUIRED_ACTIONS: Array[StringName] = [
    &"move_left",
    &"move_right",
    &"move_forward",
    &"move_back",
    &"jump",
    &"fire",
]

func run() -> Array[String]:
    var failures: Array[String] = []
    var version := Engine.get_version_info()
    _append(failures, Assertions.expect_equal(version["major"], 4, "Godot major version"))
    _append(failures, Assertions.expect_true(int(version["minor"]) >= 7, "Godot minor version must be at least 7"))
    _append(failures, Assertions.expect_equal(
        ProjectSettings.get_setting("physics/3d/physics_engine"),
        "Jolt Physics",
        "3D physics engine"
    ))
    for action in REQUIRED_ACTIONS:
        _append(failures, Assertions.expect_true(InputMap.has_action(action), "Missing input action: %s" % action))
    return failures

func _append(failures: Array[String], failure: String) -> void:
    if not failure.is_empty():
        failures.append(failure)
```

- [ ] **Step 2: Create the headless runner**

Create `tests/test_runner.gd`:

```gdscript
extends SceneTree

const TEST_PATHS: Array[String] = [
    "res://tests/unit/test_project_contract.gd",
]

func _initialize() -> void:
    var failures: Array[String] = []
    for test_path in TEST_PATHS:
        var test_script := load(test_path) as Script
        if test_script == null:
            failures.append("Unable to load %s" % test_path)
            continue
        var test_case := test_script.new()
        for failure in test_case.run():
            failures.append("%s: %s" % [test_path, failure])

    if failures.is_empty():
        print("PASS: %d test file(s)" % TEST_PATHS.size())
        quit(0)
        return

    for failure in failures:
        push_error(failure)
    print("FAIL: %d failure(s)" % failures.size())
    quit(1)
```

- [ ] **Step 3: Run the project-contract test and verify it fails**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1` with six `Missing input action` failures.

- [ ] **Step 4: Add exact display, physics-layer, and input settings**

Add these settings to `project.godot`, keeping the existing application, physics, and rendering values:

```ini
[display]

window/size/viewport_width=1280
window/size/viewport_height=720
window/size/window_width_override=1280
window/size/window_height_override=720
window/stretch/mode="canvas_items"
window/stretch/aspect="expand"

[input]

move_left={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":65,"physical_keycode":0,"key_label":0,"unicode":97,"location":0,"echo":false,"script":null)
]
}
move_right={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":68,"physical_keycode":0,"key_label":0,"unicode":100,"location":0,"echo":false,"script":null)
]
}
move_forward={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":87,"physical_keycode":0,"key_label":0,"unicode":119,"location":0,"echo":false,"script":null)
]
}
move_back={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":83,"physical_keycode":0,"key_label":0,"unicode":115,"location":0,"echo":false,"script":null)
]
}
jump={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":32,"physical_keycode":0,"key_label":0,"unicode":32,"location":0,"echo":false,"script":null)
]
}
fire={
"deadzone": 0.5,
"events": [Object(InputEventMouseButton,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"button_mask":0,"position":Vector2(0, 0),"global_position":Vector2(0, 0),"factor":1.0,"button_index":1,"canceled":false,"pressed":false,"double_click":false,"script":null)
]
}

[layer_names]

3d_physics/layer_1="World"
3d_physics/layer_2="Player"
3d_physics/layer_3="Target"
```

- [ ] **Step 5: Run the test and verify the project contract passes**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `0` and `PASS: 1 test file(s)`.

- [ ] **Step 6: Commit the project contract**

```bash
git add project.godot tests/helpers/assertions.gd tests/test_runner.gd tests/unit/test_project_contract.gd
git commit -m "test: establish gameplay project contract"
```

### Task 2: Implement camera-relative movement and grounded jumping

**Files:**
- Create: `scripts/player/player_motion.gd`
- Create: `scripts/player/player_controller.gd`
- Create: `scenes/player/Player.tscn`
- Create: `tests/unit/test_player_motion.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: input actions from Task 1 and a `Camera3D` supplied later through `PlayerController.set_aim_camera(camera: Camera3D) -> void`.
- Produces: `PlayerMotion.world_direction(input_vector: Vector2, camera_basis: Basis) -> Vector3`, `PlayerMotion.next_vertical_velocity(current_y: float, grounded: bool, jump_pressed: bool, delta: float, gravity: float, jump_speed: float) -> float`, and `res://scenes/player/Player.tscn` rooted at `CharacterBody3D`.

- [ ] **Step 1: Write the failing movement test**

Create `tests/unit/test_player_motion.gd`:

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PlayerMotion = preload("res://scripts/player/player_motion.gd")

func run() -> Array[String]:
    var failures: Array[String] = []
    var camera_basis := Basis(Vector3.UP, deg_to_rad(45.0))
    var expected_forward := -camera_basis.z
    expected_forward.y = 0.0
    expected_forward = expected_forward.normalized()

    _append(failures, Assertions.expect_vector3_near(
        PlayerMotion.world_direction(Vector2(0.0, -1.0), camera_basis),
        expected_forward,
        0.0001,
        "Forward input follows camera forward"
    ))
    _append(failures, Assertions.expect_float_near(
        PlayerMotion.world_direction(Vector2(1.0, -1.0), camera_basis).length(),
        1.0,
        0.0001,
        "Diagonal movement is normalized"
    ))
    _append(failures, Assertions.expect_float_near(
        PlayerMotion.next_vertical_velocity(0.0, true, true, 0.016, 24.0, 8.5),
        8.5,
        0.0001,
        "Grounded jump applies jump speed"
    ))
    _append(failures, Assertions.expect_float_near(
        PlayerMotion.next_vertical_velocity(2.0, false, true, 0.5, 24.0, 8.5),
        -10.0,
        0.0001,
        "Airborne jump input does not bypass gravity"
    ))
    return failures

func _append(failures: Array[String], failure: String) -> void:
    if not failure.is_empty():
        failures.append(failure)
```

Append the path to `TEST_PATHS` in `tests/test_runner.gd`:

```gdscript
    "res://tests/unit/test_player_motion.gd",
```

- [ ] **Step 2: Run the test and verify the missing movement script fails**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1` because `res://scripts/player/player_motion.gd` cannot be preloaded.

- [ ] **Step 3: Implement the pure movement calculations**

Create `scripts/player/player_motion.gd`:

```gdscript
extends RefCounted
class_name PlayerMotion

static func world_direction(input_vector: Vector2, camera_basis: Basis) -> Vector3:
    var camera_forward := -camera_basis.z
    camera_forward.y = 0.0
    camera_forward = camera_forward.normalized()

    var camera_right := camera_basis.x
    camera_right.y = 0.0
    camera_right = camera_right.normalized()

    var direction := camera_right * input_vector.x + camera_forward * -input_vector.y
    return direction.normalized() if direction.length_squared() > 1.0 else direction

static func next_vertical_velocity(
    current_y: float,
    grounded: bool,
    jump_pressed: bool,
    delta: float,
    gravity: float,
    jump_speed: float
) -> float:
    if grounded and jump_pressed:
        return jump_speed
    if not grounded:
        return current_y - gravity * delta
    return minf(current_y, 0.0)
```

- [ ] **Step 4: Run the movement test and verify it passes**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `0` and `PASS: 2 test file(s)`.

- [ ] **Step 5: Copy the exact player model dependencies**

Run:

```bash
mkdir -p assets/characters
cp docs/game_resources_zombie_prototype/assets/characters/Characters_Lis_SingleWeapon.gltf assets/characters/
cp docs/game_resources_zombie_prototype/assets/characters/Characters_Lis_SingleWeapon_Zombie_Atlas.png assets/characters/
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit-after 2
```

Expected: Godot imports both files without missing-texture errors.

- [ ] **Step 6: Implement the player controller**

Create `scripts/player/player_controller.gd`:

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
@onready var weapon: Node3D = $Weapon

var aim_camera: Camera3D
var animation_player: AnimationPlayer

func _ready() -> void:
    animation_player = visual_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
    for weapon_name in HIDDEN_WEAPONS:
        var weapon_visual := visual_root.find_child(weapon_name, true, false) as Node3D
        if weapon_visual != null:
            weapon_visual.visible = false

func set_aim_camera(camera: Camera3D) -> void:
    aim_camera = camera
    if weapon.has_method("set_aim_camera"):
        weapon.call("set_aim_camera", camera)

func face_world_point(world_point: Vector3) -> void:
    var flat_target := Vector3(world_point.x, global_position.y, world_point.z)
    if global_position.distance_squared_to(flat_target) > 0.0001:
        look_at(flat_target, Vector3.UP)

func _physics_process(delta: float) -> void:
    var input_vector := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
    var camera_basis := aim_camera.global_basis if aim_camera != null else Basis.IDENTITY
    var direction := PlayerMotion.world_direction(input_vector, camera_basis)
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

- [ ] **Step 7: Build the player scene with exact node contracts**

Create `scenes/player/Player.tscn` with this hierarchy and settings:

```text
Player (CharacterBody3D, script=player_controller.gd, collision_layer=2, collision_mask=1, floor_snap_length=0.25)
├── CollisionShape3D (CapsuleShape3D radius=0.45, height=1.8, position=(0, 0.9, 0))
├── VisualRoot (Node3D)
│   └── Characters_Lis_SingleWeapon (instance of res://assets/characters/Characters_Lis_SingleWeapon.gltf)
└── Weapon (Node3D, position=(0, 1.2, -0.35))
    └── Muzzle (Marker3D, position=(0, 0, -0.9))
```

Attach no weapon script yet; Task 4 supplies `player_weapon.gd` without changing the node names.

- [ ] **Step 8: Verify the player scene loads headlessly**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --editor --quit-after 2
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: no parse or import errors and all two test files pass.

- [ ] **Step 9: Commit player movement and jump**

```bash
git add assets/characters scenes/player scripts/player tests/test_runner.gd tests/unit/test_player_motion.gd
git commit -m "feat: add camera-relative player movement and jump"
```

### Task 3: Add the fixed-angle orthographic follow camera

**Files:**
- Create: `scripts/camera/follow_camera.gd`
- Create: `scenes/camera/FollowCamera.tscn`
- Create: `tests/unit/test_follow_camera.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: a target `Node3D`, normally the `Player` instance.
- Produces: `FollowCamera.set_target(value: Node3D) -> void`, `FollowCamera.smoothing_weight(speed: float, delta: float) -> float`, and a child camera at `Camera3D` with orthographic size `18.0`.

- [ ] **Step 1: Write the failing camera-smoothing test**

Create `tests/unit/test_follow_camera.gd`:

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const FollowCamera = preload("res://scripts/camera/follow_camera.gd")

func run() -> Array[String]:
    var failures: Array[String] = []
    _append(failures, Assertions.expect_float_near(
        FollowCamera.smoothing_weight(10.0, 0.0), 0.0, 0.0001, "Zero delta has zero camera movement"
    ))
    var one_frame := FollowCamera.smoothing_weight(10.0, 1.0 / 60.0)
    _append(failures, Assertions.expect_true(one_frame > 0.0 and one_frame < 1.0, "One frame weight is bounded"))
    _append(failures, Assertions.expect_true(
        FollowCamera.smoothing_weight(10.0, 1.0) > 0.999,
        "Long delta converges to target"
    ))
    return failures

func _append(failures: Array[String], failure: String) -> void:
    if not failure.is_empty():
        failures.append(failure)
```

Append to `TEST_PATHS`:

```gdscript
    "res://tests/unit/test_follow_camera.gd",
```

- [ ] **Step 2: Run the test and verify the missing camera script fails**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1` because `follow_camera.gd` cannot be preloaded.

- [ ] **Step 3: Implement frame-rate-independent XZ following**

Create `scripts/camera/follow_camera.gd`:

```gdscript
extends Node3D
class_name FollowCamera

@export var follow_speed: float = 10.0

var target: Node3D

static func smoothing_weight(speed: float, delta: float) -> float:
    return 1.0 - exp(-maxf(speed, 0.0) * maxf(delta, 0.0))

func set_target(value: Node3D) -> void:
    target = value
    if target != null:
        global_position.x = target.global_position.x
        global_position.z = target.global_position.z

func _physics_process(delta: float) -> void:
    if target == null:
        return
    var desired := Vector3(target.global_position.x, global_position.y, target.global_position.z)
    global_position = global_position.lerp(desired, smoothing_weight(follow_speed, delta))
```

- [ ] **Step 4: Run the camera test and verify it passes**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `0` and `PASS: 3 test file(s)`.

- [ ] **Step 5: Create the camera rig scene**

Create `scenes/camera/FollowCamera.tscn`:

```text
FollowCamera (Node3D, script=follow_camera.gd, follow_speed=10.0)
└── Camera3D (
      position=(10, 12, 10),
      rotation_degrees=(-40.3, 45, 0),
      projection=ORTHOGONAL,
      size=18.0,
      near=0.1,
      far=120.0,
      current=true
   )
```

The camera node remains a fixed child transform; only the rig root follows the player's XZ position.

- [ ] **Step 6: Verify scene parsing and commit**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --editor --quit-after 2
```

Expected: no scene parse errors.

```bash
git add scenes/camera scripts/camera tests/test_runner.gd tests/unit/test_follow_camera.gd
git commit -m "feat: add orthographic 2.5d follow camera"
```

### Task 4: Implement mouse aiming, fire cadence, and visible hitscan shots

**Files:**
- Create: `scripts/combat/aim_math.gd`
- Create: `scripts/combat/fire_gate.gd`
- Create: `scripts/combat/player_weapon.gd`
- Create: `scripts/fx/shot_tracer.gd`
- Create: `scenes/fx/ShotTracer.tscn`
- Create: `tests/unit/test_aim_and_fire.gd`
- Modify: `scenes/player/Player.tscn`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: `PlayerController.face_world_point(world_point: Vector3)`, the `Player/Weapon/Muzzle` marker, the `fire` input action, and a camera supplied by `PlayerController.set_aim_camera`.
- Produces: `AimMath.intersect_y_plane(ray_origin: Vector3, ray_direction: Vector3, plane_y: float) -> Variant`, `FireGate.tick(delta: float) -> void`, `FireGate.try_consume() -> bool`, `PlayerWeapon.set_aim_camera(camera: Camera3D) -> void`, and `ShotTracer.setup(from: Vector3, to: Vector3) -> void`.

- [ ] **Step 1: Write the failing aim and cadence test**

Create `tests/unit/test_aim_and_fire.gd`:

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const AimMath = preload("res://scripts/combat/aim_math.gd")
const FireGate = preload("res://scripts/combat/fire_gate.gd")

func run() -> Array[String]:
    var failures: Array[String] = []
    var hit := AimMath.intersect_y_plane(Vector3(0, 10, 0), Vector3(0, -1, 0), 0.0)
    _append(failures, Assertions.expect_true(hit is Vector3, "Downward ray intersects ground"))
    if hit is Vector3:
        _append(failures, Assertions.expect_vector3_near(hit, Vector3.ZERO, 0.0001, "Ground hit position"))
    _append(failures, Assertions.expect_equal(
        AimMath.intersect_y_plane(Vector3(0, 10, 0), Vector3.RIGHT, 0.0),
        null,
        "Parallel ray has no ground intersection"
    ))

    var gate := FireGate.new(1.0 / 6.0)
    _append(failures, Assertions.expect_true(gate.try_consume(), "First shot is immediately available"))
    _append(failures, Assertions.expect_true(not gate.try_consume(), "Second immediate shot is blocked"))
    gate.tick(1.0 / 6.0)
    _append(failures, Assertions.expect_true(gate.try_consume(), "Shot is available after cooldown"))
    return failures

func _append(failures: Array[String], failure: String) -> void:
    if not failure.is_empty():
        failures.append(failure)
```

Append to `TEST_PATHS`:

```gdscript
    "res://tests/unit/test_aim_and_fire.gd",
```

- [ ] **Step 2: Run the test and verify the missing combat helpers fail**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1` because the aim and fire-gate scripts do not exist.

- [ ] **Step 3: Implement ray/ground-plane intersection**

Create `scripts/combat/aim_math.gd`:

```gdscript
extends RefCounted
class_name AimMath

static func intersect_y_plane(ray_origin: Vector3, ray_direction: Vector3, plane_y: float) -> Variant:
    if absf(ray_direction.y) < 0.00001:
        return null
    var distance := (plane_y - ray_origin.y) / ray_direction.y
    if distance < 0.0:
        return null
    return ray_origin + ray_direction * distance
```

- [ ] **Step 4: Implement the deterministic fire gate**

Create `scripts/combat/fire_gate.gd`:

```gdscript
extends RefCounted
class_name FireGate

var interval: float
var remaining: float = 0.0

func _init(seconds_between_shots: float) -> void:
    interval = maxf(seconds_between_shots, 0.001)

func tick(delta: float) -> void:
    remaining = maxf(remaining - maxf(delta, 0.0), 0.0)

func try_consume() -> bool:
    if remaining > 0.0:
        return false
    remaining = interval
    return true
```

- [ ] **Step 5: Run the aim and fire test and verify it passes**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `0` and `PASS: 4 test file(s)`.

- [ ] **Step 6: Implement the tracer effect**

Create `scripts/fx/shot_tracer.gd`:

```gdscript
extends MeshInstance3D
class_name ShotTracer

@export var lifetime: float = 0.08

var remaining: float

func setup(from: Vector3, to: Vector3) -> void:
    var distance := from.distance_to(to)
    if distance <= 0.001:
        queue_free()
        return

    remaining = lifetime
    global_position = (from + to) * 0.5
    look_at(to, Vector3.UP)

    var tracer_mesh := BoxMesh.new()
    tracer_mesh.size = Vector3(0.035, 0.035, distance)
    mesh = tracer_mesh

    var material := StandardMaterial3D.new()
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.albedo_color = Color(1.0, 0.78, 0.18)
    material.emission_enabled = true
    material.emission = Color(1.0, 0.45, 0.05)
    material.emission_energy_multiplier = 3.0
    material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    material_override = material

func _process(delta: float) -> void:
    remaining -= delta
    transparency = clampf(1.0 - remaining / lifetime, 0.0, 1.0)
    if remaining <= 0.0:
        queue_free()
```

Create `scenes/fx/ShotTracer.tscn` as a `MeshInstance3D` root using `shot_tracer.gd`, with `cast_shadow=OFF` and `lifetime=0.08`.

- [ ] **Step 7: Implement camera-ray aiming and hitscan fire**

Create `scripts/combat/player_weapon.gd`:

```gdscript
extends Node3D
class_name PlayerWeapon

const AimMath = preload("res://scripts/combat/aim_math.gd")
const FireGate = preload("res://scripts/combat/fire_gate.gd")
const TRACER_SCENE := preload("res://scenes/fx/ShotTracer.tscn")

@export var shots_per_second: float = 6.0
@export var damage: float = 25.0
@export var max_range: float = 80.0
@export var aim_plane_y: float = 0.0
@export_flags_3d_physics var aim_collision_mask: int = 5

@onready var muzzle: Marker3D = $Muzzle

var aim_camera: Camera3D
var fire_gate: FireGate

func _ready() -> void:
    fire_gate = FireGate.new(1.0 / shots_per_second)

func set_aim_camera(camera: Camera3D) -> void:
    aim_camera = camera

func _physics_process(delta: float) -> void:
    fire_gate.tick(delta)
    if aim_camera == null:
        return

    var mouse_position := get_viewport().get_mouse_position()
    var ray_origin := aim_camera.project_ray_origin(mouse_position)
    var ray_direction := aim_camera.project_ray_normal(mouse_position).normalized()
    var player := get_parent() as PlayerController
    var ground_point := AimMath.intersect_y_plane(ray_origin, ray_direction, aim_plane_y)
    if ground_point is Vector3:
        player.face_world_point(ground_point)

    if Input.is_action_pressed("fire") and fire_gate.try_consume():
        _fire(ray_origin, ray_direction, player)

func _fire(ray_origin: Vector3, ray_direction: Vector3, player: PlayerController) -> void:
    var ray_end := ray_origin + ray_direction * max_range
    var query := PhysicsRayQueryParameters3D.create(
        ray_origin,
        ray_end,
        aim_collision_mask,
        [player.get_rid()]
    )
    var result := get_world_3d().direct_space_state.intersect_ray(query)
    var hit_position: Vector3 = result.get("position", ray_end)
    var collider: Object = result.get("collider", null)
    if collider != null and collider.has_method("apply_damage"):
        collider.call("apply_damage", damage, hit_position)

    var tracer := TRACER_SCENE.instantiate() as ShotTracer
    get_tree().current_scene.add_child(tracer)
    tracer.setup(muzzle.global_position, hit_position)
```

- [ ] **Step 8: Attach the weapon script and verify its exact configuration**

Modify `scenes/player/Player.tscn` so the existing `Weapon` node has:

```text
script = res://scripts/combat/player_weapon.gd
shots_per_second = 6.0
damage = 25.0
max_range = 80.0
aim_plane_y = 0.0
aim_collision_mask = 5  # World layer 1 + Target layer 3
```

- [ ] **Step 9: Run parsing and unit checks, then commit shooting**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --editor --quit-after 2
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: no parse errors and all four test files pass.

```bash
git add scenes/fx scenes/player/Player.tscn scripts/combat scripts/fx tests/test_runner.gd tests/unit/test_aim_and_fire.gd
git commit -m "feat: add mouse aiming and hitscan rifle fire"
```

### Task 5: Add damageable static zombie targets

**Files:**
- Create: `scripts/combat/health.gd`
- Create: `scripts/combat/zombie_target.gd`
- Create: `scenes/targets/ZombieTarget.tscn`
- Create: `tests/unit/test_health.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: `PlayerWeapon` calls `apply_damage(amount: float, hit_position: Vector3)` on a ray collider.
- Produces: `Health.new(maximum: float)`, `Health.apply_damage(amount: float) -> float`, `Health.changed(current: float, maximum: float)`, `Health.depleted`, and `ZombieTarget.apply_damage(amount: float, hit_position: Vector3) -> void`.

- [ ] **Step 1: Write the failing health test**

Create `tests/unit/test_health.gd`:

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const Health = preload("res://scripts/combat/health.gd")

var depleted_emissions: int = 0

func run() -> Array[String]:
    var failures: Array[String] = []
    depleted_emissions = 0
    var health := Health.new(50.0)
    health.depleted.connect(_on_depleted)
    _append(failures, Assertions.expect_float_near(health.current, 50.0, 0.0001, "Health starts full"))
    _append(failures, Assertions.expect_float_near(health.apply_damage(25.0), 25.0, 0.0001, "First shot damage"))
    _append(failures, Assertions.expect_float_near(health.current, 25.0, 0.0001, "Health after one shot"))
    _append(failures, Assertions.expect_float_near(health.apply_damage(40.0), 25.0, 0.0001, "Damage clamps at zero"))
    _append(failures, Assertions.expect_float_near(health.current, 0.0, 0.0001, "Health is depleted"))
    _append(failures, Assertions.expect_equal(depleted_emissions, 1, "Depletion signal emits once"))
    _append(failures, Assertions.expect_float_near(health.apply_damage(-10.0), 0.0, 0.0001, "Negative damage is ignored"))
    _append(failures, Assertions.expect_equal(depleted_emissions, 1, "Ignored damage does not re-emit depletion"))
    return failures

func _on_depleted() -> void:
    depleted_emissions += 1

func _append(failures: Array[String], failure: String) -> void:
    if not failure.is_empty():
        failures.append(failure)
```

Append to `TEST_PATHS`:

```gdscript
    "res://tests/unit/test_health.gd",
```

- [ ] **Step 2: Run the test and verify the missing health script fails**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1` because `health.gd` cannot be preloaded.

- [ ] **Step 3: Implement reusable clamped health**

Create `scripts/combat/health.gd`:

```gdscript
extends RefCounted
class_name Health

signal changed(current: float, maximum: float)
signal depleted

var maximum: float
var current: float

func _init(starting_maximum: float) -> void:
    maximum = maxf(starting_maximum, 1.0)
    current = maximum

func apply_damage(amount: float) -> float:
    var applied := minf(maxf(amount, 0.0), current)
    if applied <= 0.0:
        return 0.0
    current -= applied
    changed.emit(current, maximum)
    if is_zero_approx(current):
        depleted.emit()
    return applied
```

- [ ] **Step 4: Run the health test and verify it passes**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `0` and `PASS: 5 test file(s)`.

- [ ] **Step 5: Copy and import the exact zombie visual dependencies**

Run:

```bash
mkdir -p assets/enemies
cp docs/game_resources_zombie_prototype/assets/enemies/Zombie_Basic.gltf assets/enemies/
cp docs/game_resources_zombie_prototype/assets/enemies/Zombie_Basic_Zombie_Atlas.png assets/enemies/
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit-after 2
```

Expected: Godot imports the zombie model and atlas without missing-resource warnings.

- [ ] **Step 6: Implement target damage feedback and depletion**

Create `scripts/combat/zombie_target.gd`:

```gdscript
extends StaticBody3D
class_name ZombieTarget

const Health = preload("res://scripts/combat/health.gd")

@export var max_health: float = 50.0

@onready var visual_root: Node3D = $VisualRoot
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var health_label: Label3D = $HealthLabel

var health: Health
var animation_player: AnimationPlayer

func _ready() -> void:
    health = Health.new(max_health)
    health.changed.connect(_on_health_changed)
    health.depleted.connect(_on_depleted)
    animation_player = visual_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
    if animation_player != null:
        animation_player.play(&"Idle")
    _refresh_label()

func apply_damage(amount: float, _hit_position: Vector3) -> void:
    health.apply_damage(amount)
    visual_root.scale = Vector3.ONE * 1.08

func _process(delta: float) -> void:
    visual_root.scale = visual_root.scale.move_toward(Vector3.ONE, delta * 1.5)

func _on_health_changed(_current: float, _maximum: float) -> void:
    _refresh_label()

func _on_depleted() -> void:
    collision_shape.set_deferred("disabled", true)
    health_label.text = "DOWN"
    visual_root.visible = false
    await get_tree().create_timer(0.35).timeout
    queue_free()

func _refresh_label() -> void:
    health_label.text = "%d / %d" % [ceili(health.current), ceili(health.maximum)]
```

- [ ] **Step 7: Build the static zombie target scene**

Create `scenes/targets/ZombieTarget.tscn`:

```text
ZombieTarget (StaticBody3D, script=zombie_target.gd, collision_layer=4, collision_mask=0, max_health=50.0)
├── CollisionShape3D (CapsuleShape3D radius=0.5, height=1.9, position=(0, 0.95, 0))
├── VisualRoot (Node3D)
│   └── Zombie_Basic (instance of res://assets/enemies/Zombie_Basic.gltf)
└── HealthLabel (Label3D, position=(0, 2.35, 0), text="50 / 50", font_size=32, outline_size=8, billboard=ENABLED)
```

- [ ] **Step 8: Run import, parse, and unit checks, then commit**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --editor --quit-after 2
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: no parse or import errors and all five test files pass.

```bash
git add assets/enemies scenes/targets scripts/combat/health.gd scripts/combat/zombie_target.gd tests/test_runner.gd tests/unit/test_health.gd
git commit -m "feat: add damageable zombie practice targets"
```

### Task 6: Assemble the runnable 2.5D demo arena

**Files:**
- Create: `scripts/gameplay/demo_arena.gd`
- Create: `scenes/gameplay/DemoArena.tscn`
- Create: `tests/integration/test_demo_scene.gd`
- Modify: `project.godot`
- Modify: `tests/test_runner.gd`
- Copy: `assets/environment/Container_Red.gltf`
- Copy: `assets/environment/Container_Red_Zombie_Atlas.png`
- Copy: `assets/vehicles/Vehicle_Pickup.gltf`
- Copy: `assets/vehicles/Vehicle_Pickup_Zombie_Atlas.png`

**Interfaces:**
- Consumes: `PlayerController.set_aim_camera(camera: Camera3D)`, `FollowCamera.set_target(value: Node3D)`, `Player.tscn`, `FollowCamera.tscn`, and `ZombieTarget.tscn`.
- Produces: the main scene `res://scenes/gameplay/DemoArena.tscn` with nodes at `Player`, `FollowCamera/Camera3D`, `World/Ground`, `World/Targets`, and `HUD/ControlsPanel`.

- [ ] **Step 1: Write the failing scene-contract test**

Create `tests/integration/test_demo_scene.gd`:

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
    var failures: Array[String] = []
    var packed := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
    _append(failures, Assertions.expect_true(packed != null, "Demo arena scene loads"))
    if packed == null:
        return failures

    var arena := packed.instantiate()
    var player := arena.get_node_or_null("Player")
    var camera := arena.get_node_or_null("FollowCamera/Camera3D") as Camera3D
    var targets := arena.get_node_or_null("World/Targets")
    _append(failures, Assertions.expect_true(player != null, "Demo has Player"))
    _append(failures, Assertions.expect_true(player != null and player.has_method("set_aim_camera"), "Player accepts aim camera"))
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

func _append(failures: Array[String], failure: String) -> void:
    if not failure.is_empty():
        failures.append(failure)
```

Append to `TEST_PATHS`:

```gdscript
    "res://tests/integration/test_demo_scene.gd",
```

- [ ] **Step 2: Run the integration test and verify the missing scene fails**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1` with `Demo arena scene loads` failing.

- [ ] **Step 3: Copy the exact arena prop dependencies**

Run:

```bash
mkdir -p assets/environment assets/vehicles
cp docs/game_resources_zombie_prototype/assets/environment/Container_Red.gltf assets/environment/
cp docs/game_resources_zombie_prototype/assets/environment/Container_Red_Zombie_Atlas.png assets/environment/
cp docs/game_resources_zombie_prototype/assets/vehicles/Vehicle_Pickup.gltf assets/vehicles/
cp docs/game_resources_zombie_prototype/assets/vehicles/Vehicle_Pickup_Zombie_Atlas.png assets/vehicles/
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit-after 3
```

Expected: all four copied resources import without missing-texture warnings.

- [ ] **Step 4: Implement scene startup wiring**

Create `scripts/gameplay/demo_arena.gd`:

```gdscript
extends Node3D

@onready var player: PlayerController = $Player
@onready var follow_camera: FollowCamera = $FollowCamera
@onready var camera: Camera3D = $FollowCamera/Camera3D

func _ready() -> void:
    follow_camera.set_target(player)
    player.set_aim_camera(camera)
```

- [ ] **Step 5: Build the exact arena hierarchy**

Create `scenes/gameplay/DemoArena.tscn` with this hierarchy:

```text
DemoArena (Node3D, script=demo_arena.gd)
├── WorldEnvironment (WorldEnvironment)
├── Sun (DirectionalLight3D, rotation_degrees=(-55, -35, 0), shadow_enabled=true, light_energy=1.2)
├── World (Node3D)
│   ├── Ground (StaticBody3D, collision_layer=1, collision_mask=0)
│   │   ├── MeshInstance3D (BoxMesh size=(44, 0.3, 34), position=(0, -0.15, 0))
│   │   └── CollisionShape3D (BoxShape3D size=(44, 0.3, 34), position=(0, -0.15, 0))
│   ├── Boundaries (Node3D)
│   │   ├── North (StaticBody3D with BoxMesh and BoxShape3D size=(44, 2, 0.5), position=(0, 1, -17))
│   │   ├── South (StaticBody3D with BoxMesh and BoxShape3D size=(44, 2, 0.5), position=(0, 1, 17))
│   │   ├── West (StaticBody3D with BoxMesh and BoxShape3D size=(0.5, 2, 34), position=(-22, 1, 0))
│   │   └── East (StaticBody3D with BoxMesh and BoxShape3D size=(0.5, 2, 34), position=(22, 1, 0))
│   ├── Props (Node3D)
│   │   ├── PickupVisual (Vehicle_Pickup.gltf instance, position=(4, 0, 1), rotation_degrees=(0, 25, 0))
│   │   ├── PickupCollision (StaticBody3D, collision_layer=1, BoxShape3D size=(4.2, 1.8, 2.1), position=(4, 0.9, 1), rotation_degrees=(0, 25, 0))
│   │   ├── ContainerAVisual (Container_Red.gltf instance, position=(-7, 0, -5), rotation_degrees=(0, 90, 0))
│   │   ├── ContainerACollision (StaticBody3D, collision_layer=1, BoxShape3D size=(6.2, 2.8, 2.5), position=(-7, 1.4, -5), rotation_degrees=(0, 90, 0))
│   │   ├── ContainerBVisual (Container_Red.gltf instance, position=(8, 0, -8), rotation_degrees=(0, 0, 0))
│   │   └── ContainerBCollision (StaticBody3D, collision_layer=1, BoxShape3D size=(6.2, 2.8, 2.5), position=(8, 1.4, -8))
│   └── Targets (Node3D)
│       ├── ZombieTarget1 (ZombieTarget.tscn instance, position=(-4, 0, -5))
│       ├── ZombieTarget2 (ZombieTarget.tscn instance, position=(0, 0, -9))
│       ├── ZombieTarget3 (ZombieTarget.tscn instance, position=(8, 0, 6))
│       └── ZombieTarget4 (ZombieTarget.tscn instance, position=(-10, 0, 7))
├── Player (Player.tscn instance, position=(0, 0, 6))
├── FollowCamera (FollowCamera.tscn instance, position=(0, 0, 6))
└── HUD (CanvasLayer)
    ├── Title (Label, top-left, text="ZOMBIE WAR — CONTROL DEMO")
    ├── ControlsPanel (PanelContainer, bottom-left)
    │   └── Controls (Label, text="WASD  MOVE    SPACE  JUMP    LMB  FIRE")
    └── Objective (Label, top-right, text="OBJECTIVE: CLEAR 4 PRACTICE TARGETS")
```

Apply these exact presentation settings:

```text
WorldEnvironment background color: #151b22
WorldEnvironment ambient light source: COLOR
WorldEnvironment ambient light color: #8fa3b8
WorldEnvironment ambient light energy: 0.55
Ground material albedo: #39434b
Boundary material albedo: #722f37
HUD label color: #f3eee4
HUD panel background: #101419 at 82% opacity
```

- [ ] **Step 6: Configure the gameplay scene as the run target**

Add to the existing `[application]` section in `project.godot`:

```ini
run/main_scene="res://scenes/gameplay/DemoArena.tscn"
```

- [ ] **Step 7: Run the integration and unit checks**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --editor --quit-after 3
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: no parse/import errors, exit code `0`, and `PASS: 6 test file(s)`.

- [ ] **Step 8: Launch the scene and verify the first playable loop**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path . --editor project.godot
```

Press `F6` on `DemoArena.tscn`, then verify:

```text
W/A/S/D: player travels camera-relative and does not move faster diagonally
Space: player jumps from the floor and cannot jump again in mid-air
Mouse: player rotates on the ground plane toward the cursor
Hold LMB: yellow tracers appear at no more than 6 shots per second
Zombie target: label changes 50 -> 25 -> DOWN, then the target disappears
Ground/bounds/props: player collides instead of passing through
Camera: follows XZ position smoothly while preserving angle, zoom, and player visibility
```

- [ ] **Step 9: Commit the runnable demo scene**

```bash
git add project.godot assets/environment assets/vehicles scenes/gameplay scripts/gameplay tests/test_runner.gd tests/integration/test_demo_scene.gd
git commit -m "feat: assemble playable 2.5d zombie demo arena"
```

### Task 7: Document and perform the final acceptance pass

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: the complete `DemoArena.tscn` and all six automated test files.
- Produces: reproducible launch instructions, control documentation, final acceptance evidence, and an explicit boundary for the next roguelite milestone.

- [ ] **Step 1: Create the project README with exact scope and controls**

Create `README.md`:

````markdown
# Zombie War

Godot 4.7.1 2.5D zombie-game control prototype.

## Run

Open `project.godot` in Godot 4.7.1 and run the configured main scene, or use:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

## Controls

- `W/A/S/D`: camera-relative movement
- `Space`: grounded jump
- Mouse: aim on the arena floor
- Hold left mouse button: fire the rifle

## Demo scope

The demo contains one orthographic 2.5D arena, a controllable player, static collision props, and four damageable zombie practice targets. Each target has 50 health; the rifle deals 25 damage at 6 shots per second.

Enemy navigation, attacks, spawn waves, experience, upgrades, loot, and persistent roguelite runs are intentionally reserved for the next milestone.

## Tests

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```
````

- [ ] **Step 2: Run the complete automated suite from a clean Godot import**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit-after 3
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: no import/parse errors, exit code `0`, and `PASS: 6 test file(s)`.

- [ ] **Step 3: Perform the final manual acceptance matrix**

Run the project and record each row as pass:

| Requirement | Verification | Expected result |
| --- | --- | --- |
| 2.5D view | Observe and move across the arena | Orthographic angled view is maintained while all gameplay remains 3D |
| Move | Hold each WASD key, then W+D | Correct camera-relative directions; diagonal speed equals cardinal speed |
| Jump | Tap Space on ground, then tap again in air | First input jumps; airborne input does not create a second jump |
| Shoot | Aim at ground and props, hold LMB | Tracers follow the cursor ray and fire cadence remains 6 shots/second |
| Damage | Shoot one zombie target twice | Health reads `50 / 50`, `25 / 50`, `DOWN`; target disappears |
| Collision | Walk into each arena edge, pickup, and container | Player cannot pass through collision geometry |
| Camera | Run and jump near all arena edges | Camera follows smoothly without changing rotation or orthographic size |
| Resize | Resize the game window from 1280×720 | HUD stays anchored and the playable area remains visible |
| Runtime health | Watch Godot Output while playing for two minutes | No parser errors, invalid calls, missing resources, or repeated warnings |

- [ ] **Step 4: Commit the verified demo documentation**

```bash
git add README.md
git commit -m "docs: document playable zombie control demo"
```

## Self-Review

1. **Spec coverage:** The 2.5D presentation is implemented by Task 3 and integrated in Task 6; one demo scene is built and configured in Task 6; player movement and jump are covered by Task 2; aiming and firing are covered by Task 4; the zombie theme and visible damage validation are covered by Task 5. The future roguelite identity is protected by reusable combat boundaries while the actual run loop is explicitly deferred.
2. **Placeholder scan:** Every created or modified file has an exact path and responsibility. All copied assets have exact source and destination names. All code-producing steps include concrete code or an exact scene hierarchy/configuration; there are no unresolved asset choices or unnamed implementation actions.
3. **Type consistency:** `PlayerController.set_aim_camera(Camera3D)` forwards to `PlayerWeapon.set_aim_camera(Camera3D)`; `PlayerWeapon` calls `ZombieTarget.apply_damage(float, Vector3)`; `FollowCamera.set_target(Node3D)` consumes the Player root; scene node paths used by `demo_arena.gd` and the integration test exactly match the Task 6 hierarchy; the runner's final list contains exactly six test files.
