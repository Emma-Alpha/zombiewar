extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ZombieDifficultyProfile = preload("res://scripts/gameplay/zombie_difficulty_profile.gd")
const EquipmentController = preload("res://scripts/player/equipment_controller.gd")
const RangedWeapon = preload("res://scripts/combat/weapons/ranged_weapon.gd")
const MeleeWeapon = preload("res://scripts/combat/weapons/melee_weapon.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
	_append(failures, Assertions.expect_true(packed != null, "Demo arena scene loads"))
	if packed == null:
		return failures

	var arena := packed.instantiate()
	arena.set("random_seed", 20260805)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(arena)
	var player := arena.get_node_or_null("Player")
	var visual_root := arena.get_node_or_null("Player/VisualRoot") as Node3D
	var follow_camera := arena.get_node_or_null("FollowCamera") as FollowCamera
	var camera := arena.get_node_or_null("FollowCamera/Camera3D") as Camera3D
	var targets := arena.get_node_or_null("World/Targets")
	var zombies: Array[ZombieTarget] = []
	if targets != null:
		for child in targets.get_children():
			if child is ZombieTarget:
				zombies.append(child as ZombieTarget)
	var controls := arena.get_node_or_null("HUD/ControlsPanel/Controls") as Label
	var equipment := arena.get_node_or_null("Player/EquipmentController") as EquipmentController
	var hit_confirm := arena.get_node_or_null("HUD/HitConfirm") as Label
	var ground := arena.get_node_or_null("World/Ground") as StaticBody3D
	var ground_blood := arena.get_node_or_null("GroundBloodManager")
	var health_label := arena.get_node_or_null("HUD/PlayerHealth") as Label
	var damage_flash := arena.get_node_or_null("HUD/DamageFlash") as ColorRect
	var game_over := arena.get_node_or_null("HUD/GameOver") as Label
	var mobile_controls := arena.get_node_or_null("MobileControls")
	var virtual_joystick := arena.get_node_or_null(
		"MobileControls/Layout/VirtualJoystick"
	) as VirtualJoystick
	var fire_button := arena.get_node_or_null(
		"MobileControls/Layout/FireButton"
	) as MobileActionButton
	var jump_button := arena.get_node_or_null(
		"MobileControls/Layout/JumpButton"
	) as MobileActionButton
	var fire_label := arena.get_node_or_null(
		"MobileControls/Layout/FireButton/Label"
	) as Label
	var jump_label := arena.get_node_or_null(
		"MobileControls/Layout/JumpButton/Label"
	) as Label
	var difficulty := arena.get("zombie_difficulty") as ZombieDifficultyProfile
	_append(failures, Assertions.expect_true(
		difficulty != null,
		"Demo has a zombie difficulty profile"
	))
	if difficulty != null:
		_append(failures, Assertions.expect_float_near(
			difficulty.perception_move_speed,
			1.30,
			0.0001,
			"Demo defaults to normal zombie perception speed"
		))
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
		_append(failures, Assertions.expect_vector3_near(
			camera.position,
			Vector3(0.0, 12.0, sqrt(200.0)),
			0.001,
			"Camera preserves distance while moving onto the world Z axis"
		))
		_append(failures, Assertions.expect_float_near(
			camera.rotation_degrees.x,
			-40.3,
			0.0001,
			"Camera preserves the oblique pitch"
		))
		_append(failures, Assertions.expect_float_near(
			camera.rotation_degrees.y,
			0.0,
			0.0001,
			"Camera removes the 45 degree yaw"
		))
		var planar_right := camera.basis.x
		planar_right.y = 0.0
		planar_right = planar_right.normalized()
		var planar_forward := -camera.basis.z
		planar_forward.y = 0.0
		planar_forward = planar_forward.normalized()
		_append(failures, Assertions.expect_vector3_near(
			planar_right,
			Vector3.RIGHT,
			0.0001,
			"Camera right aligns with world positive X"
		))
		_append(failures, Assertions.expect_vector3_near(
			planar_forward,
			Vector3.FORWARD,
			0.0001,
			"Camera forward aligns with world negative Z"
		))
	_append(failures, Assertions.expect_true(
		targets != null and zombies.size() >= 4 and zombies.size() <= 8,
		"Demo starts with a four-to-eight zombie wave"
	))
	_append(failures, Assertions.expect_true(
		equipment != null,
		"Demo player owns the modular equipment controller"
	))
	if equipment != null:
		_append(failures, Assertions.expect_equal(
			equipment.weapons.size(),
			3,
			"Demo loadout contains pistol rifle and knife"
		))
		_append(failures, Assertions.expect_equal(
			equipment.get_current_definition().weapon_id,
			&"rifle",
			"Demo starts with the rifle equipped"
		))
		_append(failures, Assertions.expect_true(
			equipment.weapons[0] is RangedWeapon and
			equipment.weapons[1] is RangedWeapon and
			equipment.weapons[2] is MeleeWeapon,
			"Demo loadout uses two ranged runtimes and one melee runtime"
		))
	_append(failures, Assertions.expect_true(controls != null, "Demo has controls label"))
	if controls != null:
		_append(failures, Assertions.expect_equal(
			controls.text,
			"WASD MOVE + FACE   SPACE JUMP   J ATTACK   1 PISTOL   2 RIFLE   3 KNIFE",
			"HUD documents attack and weapon switching controls"
		))
	_append(failures, Assertions.expect_true(
		mobile_controls != null,
		"Demo owns a mobile controls layer"
	))
	_append(failures, Assertions.expect_true(
		virtual_joystick != null and virtual_joystick.joystick_size >= 144.0,
		"Demo has a thumb-sized native movement joystick"
	))
	_append(failures, Assertions.expect_true(
		virtual_joystick != null and
		virtual_joystick.action_left == &"move_left" and
		virtual_joystick.action_right == &"move_right" and
		virtual_joystick.action_up == &"move_forward" and
		virtual_joystick.action_down == &"move_back",
		"Native joystick maps to the existing movement actions"
	))
	_append(failures, Assertions.expect_float_near(
		virtual_joystick.deadzone_ratio if virtual_joystick != null else -1.0,
		0.15,
		0.0001,
		"Native joystick owns the radial deadzone"
	))
	_append(failures, Assertions.expect_true(
		fire_button != null and fire_button.action == &"primary_attack" and
		fire_button.size.x >= 144.0 and fire_button.size.y >= 144.0,
		"Demo has a large hold-to-fire touch button"
	))
	_append(failures, Assertions.expect_true(
		jump_button != null and jump_button.action == &"jump" and
		jump_button.size.x >= 112.0 and jump_button.size.y >= 112.0,
		"Demo has a distinct jump touch button"
	))
	_append(failures, Assertions.expect_true(
		mobile_controls != null and
		mobile_controls.get("desktop_help_path") == NodePath("../HUD/ControlsPanel"),
		"Mobile controls toggle the existing desktop help panel"
	))
	for candidate in [fire_label, jump_label]:
		var label := candidate as Label
		_append(failures, Assertions.expect_true(
			label != null,
			"Mobile action button has a readable label"
		))
		if label == null:
			continue
		var font := label.get_theme_font(&"font")
		_append(failures, Assertions.expect_true(
			font != null,
			"Mobile action label has an embedded font"
		))
		if font == null:
			continue
		for glyph in label.text:
			var codepoint := glyph.unicode_at(0)
			_append(failures, Assertions.expect_true(
				font.has_char(codepoint),
				"Mobile action font includes glyph %s" % glyph
			))
	_append(failures, Assertions.expect_true(
		hit_confirm != null and hit_confirm.modulate.a == 0.0,
		"Demo HUD has a hidden hit confirmation label"
	))
	_append(failures, Assertions.expect_true(
		ground != null and ground.is_in_group(&"blood_surface"),
		"Arena ground is the only persistent blood projection surface"
	))
	_append(failures, Assertions.expect_true(
		ground_blood != null and ground_blood.get("max_splats") == 192,
		"Arena owns a capped persistent ground blood manager"
	))
	_append(failures, Assertions.expect_true(
		hit_confirm != null,
		"Arena has shot result confirmation UI"
	))
	_append(failures, Assertions.expect_true(
		health_label != null and health_label.text == "HP 100 / 100",
		"Demo HUD starts with full player health"
	))
	_append(failures, Assertions.expect_true(
		damage_flash != null and damage_flash.color.a == 0.0,
		"Damage flash starts transparent"
	))
	_append(failures, Assertions.expect_true(
		game_over != null and not game_over.visible,
		"Game-over message starts hidden"
	))
	if targets != null:
		for target in zombies:
			_append(failures, Assertions.expect_float_near(
				float(target.get("perception_move_speed")),
				1.30,
				0.0001,
				"Every zombie receives the normal perception speed"
			))
			_append(failures, Assertions.expect_float_near(
				float(target.get("perception_range")),
				60.0,
				0.0001,
				"Every wave zombie pursues across the arena"
			))
			_append(failures, Assertions.expect_float_near(
				float(target.get("attack_range")),
				1.45,
				0.0001,
				"Every zombie keeps the fixed attack range"
			))
			_append(failures, Assertions.expect_float_near(
				float(target.get("attack_damage")),
				10.0,
				0.0001,
				"Every zombie keeps the fixed attack damage"
			))
			_append(failures, Assertions.expect_float_near(
				float(target.get("attack_windup")),
				0.50,
				0.0001,
				"Every zombie keeps the fixed attack windup"
			))
			_append(failures, Assertions.expect_float_near(
				float(target.get("attack_cooldown")),
				1.40,
				0.0001,
				"Every zombie keeps the fixed attack cooldown"
			))
			_append(failures, Assertions.expect_float_near(
				float(target.get("attack_animation_duration")),
				0.70,
				0.0001,
				"Every zombie keeps the fixed attack animation duration"
			))
			_append(failures, Assertions.expect_true(
				target is ZombieTarget and
				(target as ZombieTarget).ground_blood_requested.is_connected(
					Callable(arena, "_on_ground_blood_requested")
				),
				"Every arena target forwards blood requests to the scene manager"
			))
			_append(failures, Assertions.expect_true(
				target.has_method("set_attack_target"),
				"Every zombie exposes player targeting"
			))
			if target.has_method("set_attack_target"):
				_append(failures, Assertions.expect_true(
					target.get("attack_target") == player,
					"Every zombie targets the arena player"
				))
				_append(failures, Assertions.expect_true(
					float(target.get("attack_range")) > 0.0 and
					float(target.get("attack_damage")) > 0.0,
					"Every zombie has an enabled melee attack"
				))
	if player != null and health_label != null and game_over != null:
		player.call("apply_damage", 10.0, Vector3.ZERO)
		_append(failures, Assertions.expect_equal(
			health_label.text,
			"HP 90 / 100",
			"HUD follows player damage"
		))
		player.call("apply_damage", 1000.0, Vector3.ZERO)
		_append(failures, Assertions.expect_true(
			game_over.visible,
			"Lethal damage reveals game-over feedback"
		))
	arena.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
