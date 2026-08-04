extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const GUARD_SCENE := preload("res://scenes/ui/MobileOrientationGuard.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var guard_script := load("res://scripts/ui/mobile_orientation_guard.gd") as Script
	_append(failures, Assertions.expect_true(
		guard_script != null, "Mobile orientation guard script loads"
	))
	if guard_script == null:
		return failures

	_append(failures, Assertions.expect_true(
		not guard_script.should_block(false, Vector2(720, 1280)),
		"Desktop portrait viewport is not blocked"
	))
	_append(failures, Assertions.expect_true(
		not guard_script.should_block(true, Vector2(1280, 720)),
		"Touch landscape viewport remains playable"
	))
	_append(failures, Assertions.expect_true(
		guard_script.should_block(true, Vector2(720, 1280)),
		"Touch portrait viewport is blocked"
	))

	var tree := Engine.get_main_loop() as SceneTree
	var paused_before := tree.paused
	var viewport := SubViewport.new()
	viewport.size = Vector2i(720, 1280)
	tree.root.add_child(viewport)
	var guard := GUARD_SCENE.instantiate() as MobileOrientationGuard
	guard.force_touchscreen = true
	viewport.add_child(guard)
	_append(failures, Assertions.expect_true(
		guard.get_node("Overlay").visible and tree.paused and guard.paused_by_guard,
		"Portrait guard shows overlay and owns the pause it creates"
	))
	viewport.size = Vector2i(1280, 720)
	guard.refresh_orientation()
	_append(failures, Assertions.expect_true(
		not guard.get_node("Overlay").visible and not tree.paused and not guard.paused_by_guard,
		"Returning to landscape removes only the guard-owned pause"
	))
	viewport.free()

	tree.paused = true
	var paused_viewport := SubViewport.new()
	paused_viewport.size = Vector2i(720, 1280)
	tree.root.add_child(paused_viewport)
	var guard_during_existing_pause := GUARD_SCENE.instantiate() as MobileOrientationGuard
	guard_during_existing_pause.force_touchscreen = true
	paused_viewport.add_child(guard_during_existing_pause)
	_append(failures, Assertions.expect_true(
		guard_during_existing_pause.get_node("Overlay").visible and
		tree.paused and not guard_during_existing_pause.paused_by_guard,
		"Portrait guard preserves pause ownership when the tree is already paused"
	))
	paused_viewport.size = Vector2i(1280, 720)
	guard_during_existing_pause.refresh_orientation()
	_append(failures, Assertions.expect_true(
		not guard_during_existing_pause.get_node("Overlay").visible and
		tree.paused and not guard_during_existing_pause.paused_by_guard,
		"Returning to landscape preserves an externally owned pause"
	))
	paused_viewport.free()
	tree.paused = paused_before
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
