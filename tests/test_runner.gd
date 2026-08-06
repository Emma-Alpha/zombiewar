extends SceneTree

const TEST_PATHS: Array[String] = [
	"res://tests/unit/test_project_contract.gd",
	"res://tests/unit/test_menu_flow.gd",
	"res://tests/unit/test_player_motion.gd",
	"res://tests/unit/test_mobile_touch_controls.gd",
	"res://tests/unit/test_mobile_orientation_guard.gd",
	"res://tests/unit/test_follow_camera.gd",
	"res://tests/unit/test_directional_fire.gd",
	"res://tests/unit/test_weapon_spread_state.gd",
	"res://tests/unit/test_weapon_configuration.gd",
	"res://tests/unit/test_weapon_penetration.gd",
	"res://tests/unit/test_weapon_clearance_state.gd",
	"res://tests/unit/test_weapon_clearance_controller.gd",
	"res://tests/unit/test_weapon_loadout.gd",
	"res://tests/unit/test_player_melee_weapon.gd",
	"res://tests/unit/test_hit_result.gd",
	"res://tests/unit/test_hit_response_math.gd",
	"res://tests/unit/test_zombie_hitboxes.gd",
	"res://tests/unit/test_blood_impact.gd",
	"res://tests/unit/test_blood_trail_state.gd",
	"res://tests/unit/test_ground_blood_manager.gd",
	"res://tests/unit/test_tracer_pool.gd",
	"res://tests/unit/test_melee_attack_cycle.gd",
	"res://tests/unit/test_zombie_behavior_math.gd",
	"res://tests/unit/test_zombie_behavior.gd",
	"res://tests/unit/test_zombie_difficulty_profile.gd",
	"res://tests/unit/test_health.gd",
	"res://tests/unit/test_health_bar_3d.gd",
	"res://tests/unit/test_player_damage.gd",
	"res://tests/unit/test_weapon_feedback.gd",
	"res://tests/integration/test_weapon_wall_clearance.gd",
	"res://tests/integration/test_combat_fx_prewarm.gd",
	"res://tests/integration/test_demo_scene.gd",
	"res://tests/integration/test_demo_wave_spawning.gd",
	"res://tests/integration/test_demo_wave_controls.gd",
	"res://tests/integration/test_main_menu_scene.gd",
	"res://tests/integration/test_menu_cjk_font.gd",
	"res://tests/integration/test_cloudflare_r2_deployment.gd",
]

func _initialize() -> void:
	await process_frame
	var failures: Array[String] = []
	for test_path in TEST_PATHS:
		if test_path == "res://tests/integration/test_weapon_wall_clearance.gd":
			_release_player_input()
			await physics_frame
		var test_script := load(test_path) as Script
		if test_script == null:
			failures.append("Unable to load %s" % test_path)
			continue
		var test_case: RefCounted = test_script.new() as RefCounted
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

func _release_player_input() -> void:
	for action in [
		&"move_left",
		&"move_right",
		&"move_forward",
		&"move_back",
		&"jump",
		&"primary_attack",
		&"weapon_pistol",
		&"weapon_rifle",
		&"weapon_knife",
		&"weapon_slot_4",
	]:
		Input.action_release(action)
