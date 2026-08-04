# Zombie War Main Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a polished realtime 3D Zombie War main menu that matches the existing low-poly survival demo, starts the playable DemoArena scene, and safely exits through a confirmation dialog.

**Architecture:** The project starts in scenes/menu/MainMenu.tscn, which composes a realtime 3D showcase scene and a responsive CanvasLayer interface. A small MenuFlow state object keeps start and exit-confirmation transitions deterministic and unit-testable, while main_menu.gd owns Godot scene changes, focus, audio, and fade transitions. The existing scenes/gameplay/DemoArena.tscn remains the gameplay destination and is not coupled to menu presentation code.

**Tech Stack:** Godot 4.7.1, GDScript, Node3D, Control/CanvasLayer UI, AnimationPlayer, Tween, existing Quaternius low-poly 3D assets, Kenney CC0 interface sounds, existing custom headless GDScript test runner.

## Global Constraints

- Preserve the existing gameplay behavior in scenes/gameplay/DemoArena.tscn.
- Change application/run/main_scene from res://scenes/gameplay/DemoArena.tscn to res://scenes/menu/MainMenu.tscn.
- The main menu exposes exactly two primary actions: 开始游戏 and 退出游戏.
- 开始游戏 must transition to res://scenes/gameplay/DemoArena.tscn.
- 退出游戏 must open a confirmation dialog; only 确认退出 may call get_tree().quit().
- Default keyboard focus is 开始游戏; arrow keys and Tab use Godot built-in UI navigation; Enter/Space activates the focused button; Escape closes the exit dialog.
- Visual direction is low-poly post-apocalyptic movie poster: charcoal background, rust red accent, warning orange highlight, realtime player/zombie idle animation, slow camera drift, and subtle warning-light flicker.
- Reuse only assets already in the repository or the documented CC0 source package under docs/game_resources_zombie_prototype/.
- The menu must remain legible at 1280 × 720 and 1600 × 900 with stretch mode canvas_items and aspect expand.
- All automated tests run with /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tests/test_runner.gd.

---

## File Structure

- Create: scripts/menu/menu_flow.gd — pure state machine for READY, STARTING, and EXIT_CONFIRM states.
- Create: scripts/menu/menu_backdrop.gd — starts imported model animations and drives camera/light ambience.
- Create: scripts/menu/main_menu.gd — connects UI actions to MenuFlow, audio, fade, scene routing, and application quit.
- Create: scenes/menu/MenuBackdrop.tscn — realtime 3D composition using the player, zombie, pickup, and container assets.
- Create: scenes/menu/MainMenu.tscn — application entry scene containing the backdrop, menu UI, fade overlay, audio players, and exit dialog.
- Create: tests/unit/test_menu_flow.gd — unit tests for menu state transitions.
- Create: tests/integration/test_main_menu_scene.gd — scene contract, focus, routing, dialog, and backdrop tests.
- Modify: tests/test_runner.gd — register the two new test files.
- Modify: tests/integration/test_demo_scene.gd — keep gameplay assertions but move the project-main-scene assertion to the menu integration test.
- Modify: project.godot — configure MainMenu.tscn as the application main scene.
- Copy: assets/enemies/Zombie_Chubby.gltf — heavy zombie model used in the menu background.
- Copy: assets/enemies/Zombie_Chubby_Zombie_Atlas.png — texture referenced by the heavy zombie glTF.

### Task 1: Add a testable menu-flow state machine

**Files:**
- Create: tests/unit/test_menu_flow.gd
- Modify: tests/test_runner.gd
- Create: scripts/menu/menu_flow.gd

**Interfaces:**
- Consumes: no scene nodes; this is a pure RefCounted object.
- Produces: class MenuFlow with enum State and methods request_start() -> bool, request_exit() -> bool, cancel_exit() -> bool, and confirm_exit() -> bool.

- [ ] **Step 1: Write the failing MenuFlow unit test**

Create tests/unit/test_menu_flow.gd:

~~~gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const MenuFlow = preload("res://scripts/menu/menu_flow.gd")

func run() -> Array[String]:
	var failures: Array[String] = []

	var start_flow := MenuFlow.new()
	_append(failures, Assertions.expect_equal(
		start_flow.state,
		MenuFlow.State.READY,
		"Menu starts ready"
	))
	_append(failures, Assertions.expect_true(
		start_flow.request_start(),
		"Ready menu accepts start"
	))
	_append(failures, Assertions.expect_equal(
		start_flow.state,
		MenuFlow.State.STARTING,
		"Start request enters starting state"
	))
	_append(failures, Assertions.expect_true(
		not start_flow.request_start(),
		"Starting menu rejects duplicate start"
	))
	_append(failures, Assertions.expect_true(
		not start_flow.request_exit(),
		"Starting menu rejects exit"
	))

	var exit_flow := MenuFlow.new()
	_append(failures, Assertions.expect_true(
		exit_flow.request_exit(),
		"Ready menu opens exit confirmation"
	))
	_append(failures, Assertions.expect_equal(
		exit_flow.state,
		MenuFlow.State.EXIT_CONFIRM,
		"Exit request enters confirmation state"
	))
	_append(failures, Assertions.expect_true(
		exit_flow.confirm_exit(),
		"Confirmation state allows application exit"
	))
	_append(failures, Assertions.expect_true(
		exit_flow.cancel_exit(),
		"Confirmation can be cancelled"
	))
	_append(failures, Assertions.expect_equal(
		exit_flow.state,
		MenuFlow.State.READY,
		"Cancel returns menu to ready state"
	))
	_append(failures, Assertions.expect_true(
		not exit_flow.confirm_exit(),
		"Ready state cannot confirm application exit"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
~~~

Add the test immediately after test_project_contract.gd in TEST_PATHS:

~~~gdscript
"res://tests/unit/test_menu_flow.gd",
~~~

- [ ] **Step 2: Run the test suite and verify the new test fails**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tests/test_runner.gd
~~~

Expected: FAIL because res://scripts/menu/menu_flow.gd does not exist.

- [ ] **Step 3: Implement the minimal MenuFlow state machine**

Create scripts/menu/menu_flow.gd:

~~~gdscript
extends RefCounted
class_name MenuFlow

enum State {
	READY,
	STARTING,
	EXIT_CONFIRM,
}

var state: State = State.READY

func request_start() -> bool:
	if state != State.READY:
		return false
	state = State.STARTING
	return true

func request_exit() -> bool:
	if state != State.READY:
		return false
	state = State.EXIT_CONFIRM
	return true

func cancel_exit() -> bool:
	if state != State.EXIT_CONFIRM:
		return false
	state = State.READY
	return true

func confirm_exit() -> bool:
	return state == State.EXIT_CONFIRM
~~~

- [ ] **Step 4: Run the tests and verify MenuFlow passes**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tests/test_runner.gd
~~~

Expected: PASS with the new test included; the existing tests remain green.

- [ ] **Step 5: Commit the menu-flow contract**

~~~bash
git add scripts/menu/menu_flow.gd tests/unit/test_menu_flow.gd tests/test_runner.gd
git commit -m "test: define main menu flow"
~~~

### Task 2: Build the realtime low-poly menu backdrop

**Files:**
- Copy: assets/enemies/Zombie_Chubby.gltf
- Copy: assets/enemies/Zombie_Chubby_Zombie_Atlas.png
- Create: scripts/menu/menu_backdrop.gd
- Create: scenes/menu/MenuBackdrop.tscn
- Create: tests/integration/test_main_menu_scene.gd
- Modify: tests/test_runner.gd

**Interfaces:**
- Consumes: res://assets/characters/Characters_Lis_SingleWeapon.gltf, res://assets/enemies/Zombie_Basic.gltf, res://assets/enemies/Zombie_Chubby.gltf, res://assets/vehicles/Vehicle_Pickup.gltf, and res://assets/environment/Container_Red.gltf.
- Produces: res://scenes/menu/MenuBackdrop.tscn with nodes CameraRig/Camera3D, WarningLight, PlayerHero, ZombieBasic, ZombieChubby, Pickup, and Container.

- [ ] **Step 1: Write the failing backdrop scene contract**

Create tests/integration/test_main_menu_scene.gd with the backdrop assertions first:

~~~gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/menu/MenuBackdrop.tscn") as PackedScene
	_append(failures, Assertions.expect_true(
		packed != null,
		"Menu backdrop scene loads"
	))
	if packed == null:
		return failures

	var backdrop := packed.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(backdrop)

	_append(failures, Assertions.expect_true(
		backdrop.get_node_or_null("CameraRig/Camera3D") is Camera3D,
		"Backdrop has a camera"
	))
	_append(failures, Assertions.expect_true(
		backdrop.get_node_or_null("WarningLight") is OmniLight3D,
		"Backdrop has a warning light"
	))
	for node_path in [
		"SetDressing/PlayerHero",
		"SetDressing/ZombieBasic",
		"SetDressing/ZombieChubby",
		"SetDressing/Pickup",
		"SetDressing/Container",
	]:
		_append(failures, Assertions.expect_true(
			backdrop.get_node_or_null(node_path) != null,
			"Backdrop contains %s" % node_path
		))

	var player_animation := backdrop.get_node("SetDressing/PlayerHero").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	var basic_animation := backdrop.get_node("SetDressing/ZombieBasic").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	var chubby_animation := backdrop.get_node("SetDressing/ZombieChubby").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	_append(failures, Assertions.expect_true(
		player_animation != null and player_animation.current_animation == &"Idle_Gun",
		"Menu player uses the armed idle animation"
	))
	_append(failures, Assertions.expect_true(
		basic_animation != null and basic_animation.current_animation == &"Walk",
		"Basic zombie uses the walk animation"
	))
	_append(failures, Assertions.expect_true(
		chubby_animation != null and chubby_animation.current_animation == &"Idle_Attack",
		"Chubby zombie uses the attack idle animation"
	))

	backdrop.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
~~~

Register it at the end of TEST_PATHS:

~~~gdscript
"res://tests/integration/test_main_menu_scene.gd",
~~~

- [ ] **Step 2: Run the suite and verify the backdrop test fails**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tests/test_runner.gd
~~~

Expected: FAIL because scenes/menu/MenuBackdrop.tscn does not exist.

- [ ] **Step 3: Copy the documented heavy-zombie asset pair**

Run:

~~~bash
mkdir -p assets/enemies
cp docs/game_resources_zombie_prototype/assets/enemies/Zombie_Chubby.gltf \
  assets/enemies/Zombie_Chubby.gltf
cp docs/game_resources_zombie_prototype/assets/enemies/Zombie_Chubby_Zombie_Atlas.png \
  assets/enemies/Zombie_Chubby_Zombie_Atlas.png
~~~

Do not copy .import files; Godot regenerates them from the local project path.

- [ ] **Step 4: Implement backdrop animation and ambience behavior**

Create scripts/menu/menu_backdrop.gd:

~~~gdscript
extends Node3D

@onready var camera_rig: Node3D = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var warning_light: OmniLight3D = $WarningLight

var elapsed := 0.0
var base_camera_yaw := 0.0

func _ready() -> void:
	base_camera_yaw = camera_rig.rotation.y
	camera.look_at(Vector3(0.0, 1.35, -1.5), Vector3.UP)
	_play_model_animation($SetDressing/PlayerHero, &"Idle_Gun")
	_play_model_animation($SetDressing/ZombieBasic, &"Walk")
	_play_model_animation($SetDressing/ZombieChubby, &"Idle_Attack")

func _process(delta: float) -> void:
	elapsed += delta
	camera_rig.rotation.y = base_camera_yaw + deg_to_rad(sin(elapsed * 0.22) * 0.7)
	warning_light.light_energy = 6.2 + sin(elapsed * 2.1) * 0.45

func _play_model_animation(model_root: Node, animation_name: StringName) -> void:
	var animation_player := model_root.find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	if animation_player != null and animation_player.has_animation(animation_name):
		animation_player.play(animation_name, 0.2)
~~~

- [ ] **Step 5: Create the exact 3D backdrop composition**

Create scenes/menu/MenuBackdrop.tscn with this hierarchy:

~~~text
MenuBackdrop (Node3D, menu_backdrop.gd)
├── WorldEnvironment
├── MoonKey (DirectionalLight3D)
├── WarningLight (OmniLight3D)
├── Ground (MeshInstance3D)
├── CameraRig (Node3D)
│   └── Camera3D
└── SetDressing (Node3D)
    ├── PlayerHero (Characters_Lis_SingleWeapon.gltf)
    ├── ZombieBasic (Zombie_Basic.gltf)
    ├── ZombieChubby (Zombie_Chubby.gltf)
    ├── Pickup (Vehicle_Pickup.gltf)
    └── Container (Container_Red.gltf)
~~~

Use these exact environment values:

~~~text
Environment.background_mode = BG_COLOR
Environment.background_color = Color(0.012, 0.017, 0.019, 1)
Environment.ambient_light_source = AMBIENT_SOURCE_COLOR
Environment.ambient_light_color = Color(0.29, 0.34, 0.36, 1)
Environment.ambient_light_energy = 0.48
Environment.fog_enabled = true
Environment.fog_light_color = Color(0.16, 0.075, 0.065, 1)
Environment.fog_density = 0.018
MoonKey.rotation_degrees = Vector3(-48, -32, 0)
MoonKey.light_color = Color(0.62, 0.72, 0.78, 1)
MoonKey.light_energy = 1.15
MoonKey.shadow_enabled = true
WarningLight.position = Vector3(-3.5, 3.4, -1.0)
WarningLight.light_color = Color(1.0, 0.18, 0.08, 1)
WarningLight.light_energy = 6.2
WarningLight.omni_range = 15.0
Camera3D.position = Vector3(8.4, 4.7, 11.5)
Camera3D.fov = 46.0
~~~

Use a PlaneMesh sized Vector2(34, 26) with a StandardMaterial3D albedo color Color(0.075, 0.085, 0.087, 1), roughness 0.92, and metallic 0.08.

Place models with these exact transforms:

| Node | Position | Rotation degrees | Scale |
| --- | --- | --- | --- |
| PlayerHero | Vector3(2.8, 0, 1.4) | Vector3(0, 155, 0) | Vector3(1.08, 1.08, 1.08) |
| ZombieBasic | Vector3(0.8, 0, -4.4) | Vector3(0, -18, 0) | Vector3(1, 1, 1) |
| ZombieChubby | Vector3(5.1, 0, -6.4) | Vector3(0, -28, 0) | Vector3(1.08, 1.08, 1.08) |
| Pickup | Vector3(-0.8, 0, -2.8) | Vector3(0, 24, 0) | Vector3(1, 1, 1) |
| Container | Vector3(-6.0, 0, -5.4) | Vector3(0, 90, 0) | Vector3(1, 1, 1) |

- [ ] **Step 6: Run tests and verify the backdrop contract passes**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tests/test_runner.gd
~~~

Expected: PASS; all five set-dressing nodes exist and imported animations are playing.

- [ ] **Step 7: Commit the realtime backdrop**

~~~bash
git add \
  assets/enemies/Zombie_Chubby.gltf \
  assets/enemies/Zombie_Chubby_Zombie_Atlas.png \
  scripts/menu/menu_backdrop.gd \
  scenes/menu/MenuBackdrop.tscn \
  tests/integration/test_main_menu_scene.gd \
  tests/test_runner.gd
git commit -m "feat: add realtime zombie menu backdrop"
~~~

### Task 3: Build the responsive main-menu UI and exit confirmation

**Files:**
- Create: scripts/menu/main_menu.gd
- Create: scenes/menu/MainMenu.tscn
- Modify: tests/integration/test_main_menu_scene.gd

**Interfaces:**
- Consumes: MenuFlow, MenuBackdrop.tscn, DemoArena.tscn, and the supplied select_001.ogg, confirmation_001.ogg, and back_001.ogg audio files.
- Produces: MainMenu scene nodes named StartButton, QuitButton, ExitDialog, ConfirmExitButton, CancelExitButton, FadeOverlay, SelectAudio, ConfirmAudio, and BackAudio.

- [ ] **Step 1: Extend the integration test with the failing UI contract**

Insert these assertions after the backdrop assertions in tests/integration/test_main_menu_scene.gd:

~~~gdscript
	var menu_packed := load("res://scenes/menu/MainMenu.tscn") as PackedScene
	_append(failures, Assertions.expect_true(
		menu_packed != null,
		"Main menu scene loads"
	))
	if menu_packed == null:
		backdrop.free()
		return failures

	var menu := menu_packed.instantiate()
	tree.root.add_child(menu)
	var start_button := menu.get_node_or_null(
		"MenuLayer/MenuRoot/LeftColumn/Actions/StartButton"
	) as Button
	var quit_button := menu.get_node_or_null(
		"MenuLayer/MenuRoot/LeftColumn/Actions/QuitButton"
	) as Button
	var exit_dialog := menu.get_node_or_null(
		"MenuLayer/MenuRoot/ExitDialog"
	) as Control
	var cancel_button := menu.get_node_or_null(
		"MenuLayer/MenuRoot/ExitDialog/DialogPanel/DialogMargin/DialogContent/DialogActions/CancelExitButton"
	) as Button

	_append(failures, Assertions.expect_true(
		start_button != null and start_button.text == "开始游戏",
		"Main menu has the start action"
	))
	_append(failures, Assertions.expect_true(
		quit_button != null and quit_button.text == "退出游戏",
		"Main menu has the quit action"
	))
	_append(failures, Assertions.expect_true(
		exit_dialog != null and not exit_dialog.visible,
		"Exit dialog starts hidden"
	))
	_append(failures, Assertions.expect_true(
		menu.get("game_scene_path") == "res://scenes/gameplay/DemoArena.tscn",
		"Start action targets DemoArena"
	))
	_append(failures, Assertions.expect_true(
		ResourceLoader.exists(menu.get("game_scene_path")),
		"Configured gameplay destination exists"
	))
	_append(failures, Assertions.expect_true(
		menu.get_viewport().gui_get_focus_owner() == start_button,
		"Start button owns initial keyboard focus"
	))

	quit_button.pressed.emit()
	_append(failures, Assertions.expect_true(
		exit_dialog.visible,
		"Quit action opens confirmation"
	))
	cancel_button.pressed.emit()
	_append(failures, Assertions.expect_true(
		not exit_dialog.visible,
		"Cancel action closes confirmation"
	))

	menu.free()
~~~

- [ ] **Step 2: Run the tests and verify the main-menu UI test fails**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tests/test_runner.gd
~~~

Expected: FAIL because scenes/menu/MainMenu.tscn does not exist.

- [ ] **Step 3: Implement the main-menu controller**

Create scripts/menu/main_menu.gd:

~~~gdscript
extends Node3D

const MenuFlow = preload("res://scripts/menu/menu_flow.gd")

@export_file("*.tscn") var game_scene_path := "res://scenes/gameplay/DemoArena.tscn"

@onready var start_button: Button = %StartButton
@onready var quit_button: Button = %QuitButton
@onready var exit_dialog: Control = %ExitDialog
@onready var confirm_exit_button: Button = %ConfirmExitButton
@onready var fade_overlay: ColorRect = %FadeOverlay
@onready var select_audio: AudioStreamPlayer = $SelectAudio
@onready var confirm_audio: AudioStreamPlayer = $ConfirmAudio
@onready var back_audio: AudioStreamPlayer = $BackAudio

var flow := MenuFlow.new()

func _ready() -> void:
	start_button.grab_focus()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and flow.state == MenuFlow.State.EXIT_CONFIRM:
		_on_cancel_exit_button_pressed()
		get_viewport().set_input_as_handled()

func _on_start_button_pressed() -> void:
	if not flow.request_start():
		return
	confirm_audio.play()
	start_button.disabled = true
	quit_button.disabled = true
	var tween := create_tween()
	tween.tween_property(fade_overlay, "color:a", 1.0, 0.32)
	await tween.finished
	get_tree().change_scene_to_file(game_scene_path)

func _on_quit_button_pressed() -> void:
	if not flow.request_exit():
		return
	confirm_audio.play()
	exit_dialog.show()
	confirm_exit_button.grab_focus()

func _on_confirm_exit_button_pressed() -> void:
	if flow.confirm_exit():
		get_tree().quit()

func _on_cancel_exit_button_pressed() -> void:
	if not flow.cancel_exit():
		return
	back_audio.play()
	exit_dialog.hide()
	quit_button.grab_focus()

func _on_action_focused() -> void:
	if not select_audio.playing:
		select_audio.play()
~~~

- [ ] **Step 4: Create the responsive menu scene and exact visual styling**

Create scenes/menu/MainMenu.tscn with this hierarchy:

~~~text
MainMenu (Node3D, main_menu.gd)
├── MenuBackdrop (MenuBackdrop.tscn)
├── SelectAudio (AudioStreamPlayer)
├── ConfirmAudio (AudioStreamPlayer)
├── BackAudio (AudioStreamPlayer)
└── MenuLayer (CanvasLayer)
    └── MenuRoot (Control, full rect)
        ├── LeftShade (TextureRect, full rect)
        ├── TopAccent (ColorRect)
        ├── LeftColumn (VBoxContainer)
        │   ├── Eyebrow (Label)
        │   ├── Title (Label)
        │   ├── RedRule (ColorRect)
        │   ├── Subtitle (Label)
        │   └── Actions (VBoxContainer)
        │       ├── StartButton (Button, unique name)
        │       └── QuitButton (Button, unique name)
        ├── FooterHint (Label)
        ├── VersionLabel (Label)
        ├── FadeOverlay (ColorRect, unique name)
        └── ExitDialog (Control, unique name, hidden)
            ├── Dimmer (ColorRect)
            └── DialogPanel (PanelContainer)
                └── DialogMargin (MarginContainer)
                    └── DialogContent (VBoxContainer)
                        ├── DialogTitle (Label)
                        ├── DialogMessage (Label)
                        └── DialogActions (HBoxContainer)
                            ├── CancelExitButton (Button, unique name)
                            └── ConfirmExitButton (Button, unique name)
~~~

Assign audio streams directly from the documented source pack:

~~~text
SelectAudio.stream = res://docs/game_resources_zombie_prototype/assets/sfx/interface/Audio/select_001.ogg
ConfirmAudio.stream = res://docs/game_resources_zombie_prototype/assets/sfx/interface/Audio/confirmation_001.ogg
BackAudio.stream = res://docs/game_resources_zombie_prototype/assets/sfx/interface/Audio/back_001.ogg
~~~

Use a GradientTexture2D for LeftShade with fill_from Vector2(0, 0.5), fill_to Vector2(1, 0.5), and these gradient points:

~~~text
0.00 = Color(0.012, 0.017, 0.019, 0.98)
0.48 = Color(0.012, 0.017, 0.019, 0.86)
0.72 = Color(0.012, 0.017, 0.019, 0.28)
1.00 = Color(0.012, 0.017, 0.019, 0.00)
~~~

Use these exact UI values:

| Node | Value |
| --- | --- |
| LeftColumn anchors | left 0.07, top 0.17, right 0.43, bottom 0.82 |
| Eyebrow text | SURVIVAL PROTOTYPE |
| Eyebrow font size/color | 16 / Color(1, 0.47, 0.34, 1) |
| Title text | ZOMBIE\\nWAR |
| Title font size/color | 76 / Color(0.97, 0.95, 0.90, 1) |
| RedRule minimum size/color | Vector2(92, 5) / Color(0.71, 0.16, 0.12, 1) |
| Subtitle text | 冲出尸潮，活到最后。 |
| Subtitle font size/color | 19 / Color(0.70, 0.73, 0.70, 1) |
| StartButton minimum size | Vector2(390, 66) |
| QuitButton minimum size | Vector2(390, 66) |
| Button normal color | Color(0.075, 0.09, 0.095, 0.94) |
| Button hover/focus color | Color(0.55, 0.09, 0.07, 1) |
| Button border color | Color(0.72, 0.20, 0.14, 1) |
| Button font size | 26 |
| FooterHint text | ↑↓ / TAB 选择 · ENTER 确认 |
| VersionLabel text | v0.1 PROTOTYPE |
| DialogTitle text | 确认退出？ |
| DialogMessage text | 当前原型进度不会保存。 |
| CancelExitButton text | 返回 |
| ConfirmExitButton text | 确认退出 |
~~~

Set focus neighbors so StartButton moves down to QuitButton, QuitButton moves up to StartButton, CancelExitButton moves right to ConfirmExitButton, and ConfirmExitButton moves left to CancelExitButton.

Connect these signals:

~~~text
StartButton.pressed -> _on_start_button_pressed
QuitButton.pressed -> _on_quit_button_pressed
ConfirmExitButton.pressed -> _on_confirm_exit_button_pressed
CancelExitButton.pressed -> _on_cancel_exit_button_pressed
StartButton.focus_entered -> _on_action_focused
QuitButton.focus_entered -> _on_action_focused
StartButton.mouse_entered -> _on_action_focused
QuitButton.mouse_entered -> _on_action_focused
~~~

- [ ] **Step 5: Run tests and verify menu interaction contracts pass**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tests/test_runner.gd
~~~

Expected: PASS; Start owns initial focus, Quit opens the dialog, Cancel closes it, and the gameplay route resolves.

- [ ] **Step 6: Commit the complete menu UI**

~~~bash
git add scripts/menu/main_menu.gd scenes/menu/MainMenu.tscn tests/integration/test_main_menu_scene.gd
git commit -m "feat: add zombie war main menu"
~~~

### Task 4: Make the menu the application entry point

**Files:**
- Modify: project.godot
- Modify: tests/integration/test_demo_scene.gd
- Modify: tests/integration/test_main_menu_scene.gd

**Interfaces:**
- Consumes: res://scenes/menu/MainMenu.tscn and res://scenes/gameplay/DemoArena.tscn.
- Produces: project startup routing MainMenu -> DemoArena.

- [ ] **Step 1: Move the failing main-scene assertion to the menu test**

Delete the existing application/run/main_scene assertion from tests/integration/test_demo_scene.gd:

~~~gdscript
	var configured_main_scene: String = ProjectSettings.get_setting("application/run/main_scene", "")
	var resolved_main_scene := configured_main_scene
	if configured_main_scene.begins_with("uid://"):
		resolved_main_scene = ResourceUID.get_id_path(ResourceUID.text_to_id(configured_main_scene))
	_append(failures, Assertions.expect_equal(
		resolved_main_scene,
		"res://scenes/gameplay/DemoArena.tscn",
		"Demo arena is project main scene"
	))
~~~

Add this assertion to tests/integration/test_main_menu_scene.gd before freeing the menu:

~~~gdscript
	var configured_main_scene: String = ProjectSettings.get_setting(
		"application/run/main_scene", ""
	)
	var resolved_main_scene := configured_main_scene
	if configured_main_scene.begins_with("uid://"):
		resolved_main_scene = ResourceUID.get_id_path(
			ResourceUID.text_to_id(configured_main_scene)
		)
	_append(failures, Assertions.expect_equal(
		resolved_main_scene,
		"res://scenes/menu/MainMenu.tscn",
		"Main menu is the project entry scene"
	))
~~~

- [ ] **Step 2: Run tests and verify the project-entry assertion fails**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tests/test_runner.gd
~~~

Expected: FAIL because project.godot still points to DemoArena.tscn.

- [ ] **Step 3: Change the application main scene**

Update project.godot:

~~~ini
[application]

config/name="zombiewar"
config/features=PackedStringArray("4.7", "GL Compatibility")
config/icon="res://icon.svg"
run/main_scene="res://scenes/menu/MainMenu.tscn"
~~~

- [ ] **Step 4: Run the complete automated suite**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tests/test_runner.gd
~~~

Expected: PASS for all registered test files.

- [ ] **Step 5: Commit application routing**

~~~bash
git add project.godot tests/integration/test_demo_scene.gd tests/integration/test_main_menu_scene.gd
git commit -m "feat: launch game through main menu"
~~~

### Task 5: Verify the final visual and interaction experience

**Files:**
- Verify: scenes/menu/MainMenu.tscn
- Verify: scenes/menu/MenuBackdrop.tscn
- Verify: scenes/gameplay/DemoArena.tscn

**Interfaces:**
- Consumes: completed menu, backdrop, audio, and application routing.
- Produces: a verified desktop main-menu experience at the supported resolutions.

- [ ] **Step 1: Launch the project from its configured entry scene**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
~~~

Expected: the application opens directly on the Zombie War menu at 1280 × 720.

- [ ] **Step 2: Verify the visual composition**

Confirm every item:

~~~text
[ ] Left-side title and buttons remain readable over the gradient shade.
[ ] The armed player is visible in the right foreground.
[ ] The pickup and red container form the middle-ground silhouette.
[ ] Basic and chubby zombies remain visible behind the player without covering buttons.
[ ] Player animation is Idle_Gun.
[ ] Basic zombie animation is Walk.
[ ] Chubby zombie animation is Idle_Attack.
[ ] Camera drift is subtle and does not cause motion sickness.
[ ] Warning light flicker stays between energy 5.75 and 6.65.
[ ] No missing-resource or parser errors appear in Godot output.
~~~

- [ ] **Step 3: Verify mouse and keyboard interactions**

Confirm every item:

~~~text
[ ] StartButton has initial focus.
[ ] Down or Tab moves focus to 退出游戏.
[ ] Up or Shift+Tab returns focus to 开始游戏.
[ ] Mouse hover and keyboard focus use the same rust-red highlight.
[ ] Focus and hover play select_001.ogg without overlapping repeatedly.
[ ] 退出游戏 opens the confirmation dialog instead of immediately closing.
[ ] Escape closes the confirmation dialog and restores focus to 退出游戏.
[ ] 返回 closes the confirmation dialog.
[ ] 确认退出 closes the application.
~~~

- [ ] **Step 4: Verify gameplay routing**

Relaunch the project, activate 开始游戏, and confirm:

~~~text
[ ] confirmation_001.ogg plays.
[ ] The screen fades to black in 0.32 seconds.
[ ] scenes/gameplay/DemoArena.tscn loads.
[ ] WASD movement, Space jump, and J fire still work.
[ ] Four zombie practice targets remain present.
~~~

- [ ] **Step 5: Verify responsive layout at 1600 × 900**

Resize the window to 1600 × 900.

Expected: the left column keeps its relative position, the two buttons stay at least 390 × 66 logical pixels, dialog remains centered, and no text is clipped.

- [ ] **Step 6: Run the final headless regression suite**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tests/test_runner.gd
~~~

Expected: PASS for all registered test files.

- [ ] **Step 7: Commit any verification-only adjustments**

If visual verification required numeric property adjustments, stage only the menu files that changed:

~~~bash
git add scenes/menu/MainMenu.tscn scenes/menu/MenuBackdrop.tscn scripts/menu/main_menu.gd scripts/menu/menu_backdrop.gd
git commit -m "style: refine main menu presentation"
~~~

If no files changed during verification, do not create an empty commit.

## Self-Review

1. **Spec coverage:** The plan covers the agreed low-poly movie-poster composition, existing demo assets, two primary actions, real gameplay routing, exit confirmation, keyboard/mouse navigation, audio feedback, responsive layouts, animations, camera motion, warning-light ambience, and regression tests. No requested behavior is missing.
2. **Placeholder scan:** Every file path, model, animation, audio file, color, node name, scene destination, test command, and interaction is concrete. No unresolved implementation marker remains.
3. **Type consistency:** MenuFlow method names and enum states match the unit test and main_menu.gd. Main-menu node names match the controller and integration test. GAME routing consistently targets res://scenes/gameplay/DemoArena.tscn, while application startup consistently targets res://scenes/menu/MainMenu.tscn.
