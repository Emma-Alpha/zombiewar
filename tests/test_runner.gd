extends SceneTree

const TestPathSelection = preload("res://tests/helpers/test_path_selection.gd")
const TEST_PATHS: Array[String] = [
	"res://tests/unit/test_project_contract.gd",
	"res://tests/unit/test_menu_flow.gd",
	"res://tests/unit/test_player_motion.gd",
	"res://tests/unit/test_mobile_touch_controls.gd",
	"res://tests/unit/test_mobile_orientation_guard.gd",
	"res://tests/unit/test_follow_camera.gd",
	"res://tests/unit/test_directional_fire.gd",
	"res://tests/unit/test_weapon_spread_state.gd",
	"res://tests/unit/test_explosion_math.gd",
	"res://tests/unit/test_explosive_barrel.gd",
	"res://tests/unit/test_place_item_grid.gd",
	"res://tests/unit/test_test_path_selection.gd",
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
	"res://tests/unit/test_navigation_bake_state.gd",
	"res://tests/unit/test_navigation_chunk_3d.gd",
	"res://tests/unit/test_navigation_world_manager.gd",
	"res://tests/unit/test_health.gd",
	"res://tests/unit/test_health_bar_3d.gd",
	"res://tests/unit/test_player_damage.gd",
	"res://tests/unit/test_weapon_feedback.gd",
	"res://tests/integration/test_weapon_wall_clearance.gd",
	"res://tests/integration/test_player_place_item_input.gd",
	"res://tests/integration/test_place_item_grid_physics.gd",
	"res://tests/integration/test_place_item_controller.gd",
	"res://tests/integration/test_checkpoint_prop_scenes.gd",
	"res://tests/integration/test_demo_arena_extent.gd",
	"res://tests/integration/test_fallen_checkpoint_scene.gd",
	"res://tests/integration/test_demo_place_item.gd",
	"res://tests/integration/test_explosive_barrel_scene.gd",
	"res://tests/integration/test_combat_fx_prewarm.gd",
	"res://tests/integration/test_demo_scene.gd",
	"res://tests/integration/test_demo_navigation.gd",
	"res://tests/integration/test_demo_wave_spawning.gd",
	"res://tests/integration/test_demo_wave_controls.gd",
	"res://tests/integration/test_main_menu_scene.gd",
	"res://tests/integration/test_menu_cjk_font.gd",
	"res://tests/integration/test_cloudflare_r2_deployment.gd",
]

func _initialize() -> void:
	await process_frame
	var failures: Array[String] = []
	var requested_paths: Array[String] = []
	requested_paths.assign(OS.get_cmdline_user_args())
	var selection: Dictionary = TestPathSelection.select_paths(
		TEST_PATHS,
		requested_paths
	)
	var selection_errors: Array[String] = []
	selection_errors.assign(selection["errors"])
	if not selection_errors.is_empty():
		for selection_error in selection_errors:
			push_error(selection_error)
		print("FAIL: %d invalid test path(s)" % selection_errors.size())
		quit(1)
		return
	var selected_paths: Array[String] = []
	selected_paths.assign(selection["paths"])
	for test_path in selected_paths:
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
		print("PASS: %d test file(s)" % selected_paths.size())
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
		&"place_item",
		&"primary_attack",
		&"weapon_pistol",
		&"weapon_rifle",
		&"weapon_knife",
		&"weapon_slot_4",
	]:
		Input.action_release(action)
