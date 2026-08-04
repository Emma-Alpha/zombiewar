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
	var spawn_wave_button := arena.get_node_or_null("HUD/SpawnWaveButton") as Button
	var restart_button := arena.get_node_or_null("HUD/RestartButton") as Button
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

	var before_button := int(arena.call("get_active_zombie_count"))
	if spawn_wave_button != null:
		spawn_wave_button.pressed.emit()
	var after_button := int(arena.call("get_active_zombie_count"))
	_append(failures, Assertions.expect_true(
		after_button > before_button,
		"Spawn-wave button appends a wave while alive"
	))

	var before_top_edge_click := int(arena.call("get_active_zombie_count"))
	if spawn_wave_button != null:
		_click_at(
			tree.root.get_viewport(),
			spawn_wave_button.get_global_rect().position + Vector2(16.0, 8.0)
		)
	_append(failures, Assertions.expect_true(
		int(arena.call("get_active_zombie_count")) > before_top_edge_click,
		"Pointer click through the hit-confirm overlap spawns a wave"
	))

	var before_t := int(arena.call("get_active_zombie_count"))
	arena.call("_unhandled_input", _pressed_action(&"spawn_wave"))
	_append(failures, Assertions.expect_true(
		int(arena.call("get_active_zombie_count")) > before_t,
		"T uses the same live wave request"
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
		game_over.text == "PLAYER DOWN",
		"Death HUD shows the defeat state"
	))
	_append(failures, Assertions.expect_true(
		objective != null and objective.text.contains("FINAL WAVE"),
		"Death HUD preserves final wave information"
	))

	var defeated_count := int(arena.call("get_active_zombie_count"))
	_append(failures, Assertions.expect_true(
		spawn_wave_button != null and not spawn_wave_button.visible and
		restart_button != null and restart_button.visible,
		"Death swaps the spawn command for the centered restart command"
	))

	if spawn_wave_button != null:
		spawn_wave_button.pressed.emit()
	_append(failures, Assertions.expect_equal(
		int(arena.call("get_active_zombie_count")),
		defeated_count,
		"Spawn-wave button is ignored after player death"
	))

	if restart_button != null:
		restart_button.pressed.emit()
	_append(failures, Assertions.expect_equal(
		restart_emissions[0],
		1,
		"Dead-player restart button requests one scene reload"
	))
	arena.call("_unhandled_input", _pressed_action(&"restart_demo"))
	_append(failures, Assertions.expect_equal(
		restart_emissions[0],
		1,
		"Restart pending blocks duplicate button or R requests"
	))

	arena.free()
	_append_auto_wave_failures(failures, packed, tree)
	return failures

func _append_auto_wave_failures(
	failures: Array[String],
	packed: PackedScene,
	tree: SceneTree
) -> void:
	var arena := packed.instantiate()
	arena.set("random_seed", 20260805)
	tree.root.add_child(arena)
	var timer := arena.get_node_or_null("AutoWaveTimer") as Timer
	var wave_status := arena.get_node_or_null("HUD/WaveStatus") as Label
	var player := arena.get_node_or_null("Player") as PlayerController
	var targets := arena.get_node_or_null("World/Targets")
	_append(failures, Assertions.expect_true(
		targets != null and targets.child_exiting_tree.is_connected(
			arena._on_target_exiting_tree
		),
		"Target removal is connected to automatic-wave scheduling"
	))
	_append(failures, Assertions.expect_true(
		timer != null and timer.timeout.is_connected(arena._on_auto_wave_timeout),
		"Auto-wave timer timeout is connected to the wave request"
	))

	_clear_zombies(arena)
	arena.call("_refresh_wave_state_after_target_exit")
	_append(failures, Assertions.expect_true(
		timer != null and not timer.is_stopped() and
		wave_status != null and wave_status.visible and
		wave_status.text == "下一波即将到来",
		"Clearing the arena schedules one delayed wave"
	))
	_append(failures, Assertions.expect_true(
		not bool(arena.call("_schedule_auto_wave_if_empty")),
		"A running auto-wave timer cannot be scheduled twice"
	))

	var wave_before_manual := int(arena.get("wave_number"))
	arena.call("request_spawn_wave")
	_append(failures, Assertions.expect_true(
		timer != null and timer.is_stopped() and
		wave_status != null and not wave_status.visible and
		int(arena.get("wave_number")) == wave_before_manual + 1,
		"Manual wave skips the delay without leaving a second wave pending"
	))

	_clear_zombies(arena)
	arena.call("_schedule_auto_wave_if_empty")
	var wave_before_auto := int(arena.get("wave_number"))
	if timer != null:
		timer.timeout.emit()
	_append(failures, Assertions.expect_true(
		int(arena.get("wave_number")) == wave_before_auto + 1 and
		int(arena.call("get_active_zombie_count")) >= 4,
		"Auto-wave Timer timeout creates the next four-corner wave"
	))

	_clear_zombies(arena)
	arena.call("_schedule_auto_wave_if_empty")
	if player != null:
		player.apply_damage(1000.0, Vector3.ZERO)
	var defeated_wave := int(arena.get("wave_number"))
	arena.call("_on_auto_wave_timeout")
	_append(failures, Assertions.expect_true(
		timer != null and timer.is_stopped() and
		int(arena.get("wave_number")) == defeated_wave and
		int(arena.call("get_active_zombie_count")) == 0,
		"Player death cancels and blocks the pending automatic wave"
	))
	arena.free()

func _clear_zombies(arena: Node) -> void:
	var targets := arena.get_node_or_null("World/Targets")
	if targets == null:
		return
	for child in targets.get_children():
		if child is ZombieTarget:
			targets.remove_child(child)
			child.free()

func _pressed_action(action: StringName) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	return event

func _click_at(viewport: Viewport, position: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.position = position
	press.global_position = position
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	viewport.push_input(press, true)
	var release := InputEventMouseButton.new()
	release.position = position
	release.global_position = position
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	viewport.push_input(release, true)

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
