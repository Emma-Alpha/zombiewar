extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
	_append(failures, Assertions.expect_true(
		packed != null,
		"Wave control test loads DemoArena"
	))
	if packed == null:
		return failures

	var arena := packed.instantiate()
	arena.set("random_seed", 20260805)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(arena)

	var player := arena.get_node_or_null("Player") as PlayerController
	var objective := arena.get_node_or_null("HUD/Objective") as Label
	var wave_status := arena.get_node_or_null("HUD/WaveStatus") as Label
	var game_over := arena.get_node_or_null("HUD/GameOver") as Label
	var controls := arena.get_node_or_null("HUD/ControlsPanel/Controls") as Label
	var restart_emissions := [0]
	if arena.has_signal("restart_requested"):
		arena.connect("restart_requested", func() -> void:
			restart_emissions[0] += 1
		)

	_append(failures, Assertions.expect_true(
		objective != null and
		objective.text.contains("WAVE 1") and
		objective.text.contains("T: NEW WAVE"),
		"Live HUD shows wave number and T help"
	))
	_append(failures, Assertions.expect_true(
		controls != null and
		controls.text.contains("T  WAVE") and
		controls.text.contains("R  RESTART"),
		"Desktop help documents wave and restart controls"
	))

	var before_t := int(arena.call("get_active_zombie_count"))
	arena.call("_unhandled_input", _pressed_action(&"spawn_wave"))
	var after_t := int(arena.call("get_active_zombie_count"))
	_append(failures, Assertions.expect_true(
		after_t > before_t,
		"T appends a wave while the player is alive"
	))

	arena.call("_unhandled_input", _pressed_action(&"restart_demo"))
	_append(failures, Assertions.expect_equal(
		restart_emissions[0],
		0,
		"R does nothing while the player is alive"
	))

	for _index in range(8):
		arena.call("spawn_wave")
	arena.call("_unhandled_input", _pressed_action(&"spawn_wave"))
	_append(failures, Assertions.expect_true(
		wave_status != null and
		wave_status.visible and
		wave_status.text == "MAX ZOMBIES: 24",
		"Full arena reports the zombie cap"
	))

	if player != null:
		player.apply_damage(1000.0, Vector3.ZERO)
	_append(failures, Assertions.expect_true(
		bool(arena.get("player_defeated")),
		"Lethal damage marks the arena defeated"
	))
	_append(failures, Assertions.expect_true(
		game_over != null and
		game_over.visible and
		game_over.text == "PLAYER DOWN\nPRESS R TO RESTART",
		"Death HUD explains the R restart"
	))
	_append(failures, Assertions.expect_true(
		objective != null and objective.text.contains("FINAL WAVE"),
		"Death HUD preserves final wave information"
	))

	var defeated_count := int(arena.call("get_active_zombie_count"))
	arena.call("_unhandled_input", _pressed_action(&"spawn_wave"))
	_append(failures, Assertions.expect_equal(
		int(arena.call("get_active_zombie_count")),
		defeated_count,
		"T is ignored after player death"
	))

	arena.call("_unhandled_input", _pressed_action(&"restart_demo"))
	_append(failures, Assertions.expect_equal(
		restart_emissions[0],
		1,
		"Dead-player R requests exactly one scene reload"
	))

	arena.free()
	return failures

func _pressed_action(action: StringName) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	return event

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
