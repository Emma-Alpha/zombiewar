extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ZombieDifficultyProfile = preload("res://scripts/gameplay/zombie_difficulty_profile.gd")
const EquipmentController = preload("res://scripts/player/equipment_controller.gd")
const RangedWeapon = preload("res://scripts/combat/weapons/ranged_weapon.gd")
const MeleeWeapon = preload("res://scripts/combat/weapons/melee_weapon.gd")
const HitResult = preload("res://scripts/combat/hit_result.gd")
const ZOMBIE_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")

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
	var navigation_manager := arena.get_node_or_null(
		"World/Navigation"
	) as NavigationWorldManager
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
	var legacy_health_label := arena.get_node_or_null("HUD/PlayerHealth") as Label
	var health_bar := arena.get_node_or_null("Player/HealthBar3D") as HealthBar3D
	var damage_flash := arena.get_node_or_null("HUD/DamageFlash") as ColorRect
	var game_over := arena.get_node_or_null("HUD/GameOver") as Label
	var wave_status := arena.get_node_or_null("HUD/WaveStatus") as Label
	var wave_status_timer := arena.get_node_or_null("WaveStatusTimer") as Timer
	var auto_wave_timer := arena.get_node_or_null("AutoWaveTimer") as Timer
	var spawn_wave_button := arena.get_node_or_null("HUD/SpawnWaveButton") as Button
	var restart_button := arena.get_node_or_null("HUD/RestartButton") as Button
	var mobile_controls := arena.get_node_or_null("MobileControls")
	var orientation_guard := arena.get_node_or_null("MobileOrientationGuard") as MobileOrientationGuard
	var virtual_joystick := arena.get_node_or_null(
		"MobileControls/Layout/VirtualJoystick"
	) as VirtualJoystick
	var fire_button := arena.get_node_or_null(
		"MobileControls/Layout/FireButton"
	) as MobileActionButton
	var place_item_button := arena.get_node_or_null(
		"MobileControls/Layout/PlaceItemButton"
	) as MobileActionButton
	var fire_label := arena.get_node_or_null(
		"MobileControls/Layout/FireButton/Label"
	) as Label
	var place_item_label := arena.get_node_or_null(
		"MobileControls/Layout/PlaceItemButton/Label"
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
	var weapon_collision := arena.get_node_or_null(
		"Player/WeaponCollision"
	) as CollisionShape3D
	var weapon_clearance := arena.get_node_or_null(
		"Player/WeaponClearanceController"
	)
	_append(failures, Assertions.expect_true(
		weapon_collision != null and weapon_clearance != null,
		"Demo player owns fitted weapon wall clearance"
	))
	if player != null:
		_append(failures, Assertions.expect_float_near(
			float(player.get("move_speed")), 5.0, 0.0001, "Player tuned move speed"
		))
		_append(failures, Assertions.expect_float_near(
			float(player.get("ground_acceleration")), 30.0, 0.0001,
			"Player tuned ground acceleration"
		))
		_append(failures, Assertions.expect_float_near(
			float(player.get("ground_deceleration")), 42.0, 0.0001,
			"Player tuned ground deceleration"
		))
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
		_append(failures, Assertions.expect_float_near(camera.size, 15.0, 0.0001, "Camera orthographic size"))
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
		navigation_manager != null and
		navigation_manager.chunk_bake_failed.is_connected(
			Callable(arena, "_on_navigation_chunk_bake_failed")
		),
		"Demo reports navigation bake failures"
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
		_append(failures, Assertions.expect_true(
			controls.text.contains("K") and
			controls.text.contains("油桶") and
			controls.text.contains("999"),
			"HUD documents the configured place item and inventory"
		))
	_append(failures, Assertions.expect_equal(
		place_item_label.text if place_item_label != null else "",
		"油桶\n999",
		"Demo initializes the mobile place-item label from its inventory"
	))
	_append(failures, Assertions.expect_true(
		mobile_controls != null,
		"Demo owns a mobile controls layer"
	))
	_append(failures, Assertions.expect_true(
		orientation_guard != null and
		orientation_guard.input_cancel_target_path == NodePath("../MobileControls"),
		"Demo blocks portrait play and releases mobile controls"
	))
	var demo_viewport_height := tree.root.get_visible_rect().size.y
	var expected_demo_joystick_size := demo_viewport_height * 0.45
	var expected_demo_fire_size := expected_demo_joystick_size * 160.0 / 252.0
	_append(failures, Assertions.expect_true(
		virtual_joystick != null and
		virtual_joystick.size.is_equal_approx(
			Vector2.ONE * expected_demo_joystick_size
		) and
		is_equal_approx(
			virtual_joystick.joystick_size,
			expected_demo_joystick_size * 204.0 / 252.0
		) and
		is_equal_approx(
			virtual_joystick.tip_size,
			expected_demo_joystick_size * 88.0 / 252.0
		),
		"Demo sizes the native movement joystick to 45 percent of viewport height"
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
		0.12,
		0.0001,
		"Native joystick uses the tuned radial deadzone"
	))
	_append(failures, Assertions.expect_true(
		fire_button != null and fire_button.action == &"primary_attack" and
		fire_button.size.is_equal_approx(Vector2.ONE * expected_demo_fire_size),
		"Demo scales the hold-to-fire button with the movement joystick"
	))
	_append(failures, Assertions.expect_true(
		place_item_button != null and place_item_button.action == &"place_item" and
		place_item_button.size.is_equal_approx(Vector2(120.0, 120.0)),
		"Demo keeps a distinct fixed-size place-item touch button"
	))
	_append(failures, Assertions.expect_true(
		virtual_joystick != null and fire_button != null and place_item_button != null and
		not virtual_joystick.get_global_rect().intersects(fire_button.get_global_rect()) and
		not virtual_joystick.get_global_rect().intersects(place_item_button.get_global_rect()) and
		not fire_button.get_global_rect().intersects(place_item_button.get_global_rect()),
		"Demo responsive touch targets do not overlap"
	))
	_append(failures, Assertions.expect_true(
		mobile_controls != null and
		mobile_controls.get("desktop_help_path") == NodePath("../HUD/ControlsPanel"),
		"Mobile controls toggle the existing desktop help panel"
	))
	_append(failures, Assertions.expect_true(
		spawn_wave_button != null and
		spawn_wave_button.get_parent() == arena.get_node_or_null("HUD") and
		spawn_wave_button.size.x >= 176.0 and
		spawn_wave_button.size.y >= 56.0 and
		spawn_wave_button.visible,
		"Demo exposes a live cross-platform spawn-wave button"
	))
	_append(failures, Assertions.expect_true(
		restart_button != null and
		restart_button.get_parent() == arena.get_node_or_null("HUD") and
		restart_button.size.x >= 240.0 and
		restart_button.size.y >= 72.0 and
		not restart_button.visible,
		"Demo keeps the centered restart button hidden while alive"
	))
	for command_button in [spawn_wave_button, restart_button]:
		var button := command_button as Button
		_append(failures, Assertions.expect_true(
			button != null and button.get_theme_font(&"font") != null,
			"Cross-platform command button has the Chinese UI font"
		))
		if button == null or button.get_theme_font(&"font") == null:
			continue
		for glyph in button.text:
			_append(failures, Assertions.expect_true(
				button.get_theme_font(&"font").has_char(glyph.unicode_at(0)),
				"Command button font includes glyph %s" % glyph
			))
	_append(failures, Assertions.expect_true(
		wave_status != null and wave_status.get_theme_font(&"font") != null,
		"Automatic wave status has the Chinese UI font"
	))
	for glyph in "下一波即将到来":
		_append(failures, Assertions.expect_true(
			wave_status != null and
			wave_status.get_theme_font(&"font") != null and
			wave_status.get_theme_font(&"font").has_char(glyph.unicode_at(0)),
			"Automatic wave status font includes glyph %s" % glyph
		))
	for candidate in [fire_label, place_item_label]:
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
			if glyph == "\n":
				continue
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
		hit_confirm != null and
		hit_confirm.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"Hit confirmation ignores pointer input above the spawn-wave button"
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
	if hit_confirm != null:
		arena.call(
			"_on_player_attack",
			Vector3.FORWARD,
			HitResult.resolved(10.0, &"body", true, false, Vector3.ZERO),
			0.0
		)
		_append(failures, Assertions.expect_equal(
			hit_confirm.text,
			"HIT",
			"HUD shows a normal hit even when it receives a legacy critical result"
		))
		_append(failures, Assertions.expect_equal(
			hit_confirm.modulate,
			Color.WHITE,
			"HUD keeps normal-hit confirmation white"
		))
	_append(failures, Assertions.expect_true(
		legacy_health_label == null,
		"Demo removes the legacy player-health HUD"
	))
	_append(failures, Assertions.expect_true(
		health_bar != null,
		"Demo player has an overhead health bar"
	))
	_append(failures, Assertions.expect_true(
		damage_flash != null and damage_flash.color.a == 0.0,
		"Damage flash starts transparent"
	))
	_append(failures, Assertions.expect_true(
		game_over != null and not game_over.visible,
		"Game-over message starts hidden"
	))
	_append(failures, Assertions.expect_true(
		wave_status != null and not wave_status.visible,
		"Wave status starts hidden"
	))
	_append(failures, Assertions.expect_true(
		wave_status_timer != null and
		wave_status_timer.one_shot and
		absf(wave_status_timer.wait_time - 1.2) <= 0.0001,
		"Wave status uses a short one-shot timer"
	))
	_append(failures, Assertions.expect_true(
		auto_wave_timer != null and
		auto_wave_timer.one_shot and
		absf(auto_wave_timer.wait_time - 1.5) <= 0.0001 and
		auto_wave_timer.is_stopped(),
		"Demo owns a stopped 1.5-second one-shot auto-wave timer"
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
				target.ground_blood_trail_requested.is_connected(
					Callable(arena, "_on_ground_blood_trail_requested")
				),
				"Every arena target forwards real knockback movement to the blood manager"
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
	if player != null and equipment != null and targets != null:
		var direct_target := ZOMBIE_SCENE.instantiate() as ZombieTarget
		direct_target.position = targets.to_local(
			player.global_position + Vector3.FORWARD * 8.0
		)
		direct_target.set_physics_process(false)
		targets.add_child(direct_target)
		equipment.equip_slot(1)
		var rifle := equipment.get_current_weapon() as RangedWeapon
		if rifle != null:
			rifle.call("_fire", Vector3.FORWARD)
		_append(failures, Assertions.expect_float_near(
			direct_target.health.current,
			25.0,
			0.0001,
			"Arena rifle ray clears the floor and damages a centered Zombie"
		))
		direct_target.free()
	if player != null and health_bar != null and game_over != null:
		player.call("apply_damage", 10.0, Vector3.ZERO)
		_append(failures, Assertions.expect_float_near(
			health_bar.get_target_ratio(),
			0.9,
			0.0001,
			"Overhead health bar follows player damage"
		))
		player.call("apply_damage", 1000.0, Vector3.ZERO)
		_append(failures, Assertions.expect_float_near(
			health_bar.get_target_ratio(),
			0.0,
			0.0001,
			"Overhead health bar empties on player death"
		))
		_append(failures, Assertions.expect_true(
			game_over.visible and game_over.text == "PLAYER DOWN",
			"Lethal damage reveals game-over feedback"
		))
	arena.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
