extends SceneTree

const DescriptorScript = preload("res://scripts/input/local_player_descriptor.gd")
const ZombieScene = preload("res://scenes/targets/ZombieTarget.tscn")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var session = root.get_node("GameSession")
	session.configure_local([
		_descriptor(DescriptorScript.SourceKind.KEYBOARD_WASD),
		_descriptor(DescriptorScript.SourceKind.KEYBOARD_ARROWS),
	])
	var scene := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
	var arena = scene.instantiate()
	arena.minimum_zombies_per_corner = 1
	arena.maximum_zombies_per_corner = 1
	root.add_child(arena)
	await process_frame
	var registry = arena.get_node_or_null("PlayerRegistry")
	_expect(registry != null, "DemoArena must contain PlayerRegistry", failures)
	if registry != null:
		_expect(registry.get_players().size() == 2, "DemoArena must register every spawned player", failures)
		for player in arena.get_node("Players").get_children():
			_expect(registry.get_players().has(player), "registry must contain each Players child", failures)
	var targets := arena.get_node("World/Targets")
	_expect(targets.get_child_count() > 0, "headless arena startup must spawn validation zombies", failures)
	for target in targets.get_children():
		if target is ZombieTarget:
			_expect(target.player_registry == registry, "spawned zombie must receive the arena registry", failures)

	var late_target = ZombieScene.instantiate()
	targets.add_child(late_target)
	_expect(late_target.player_registry == registry, "late zombie must receive the same arena registry", failures)

	arena.queue_free()
	await process_frame
	session.clear()
	_finish(failures)

func _descriptor(source_kind: int):
	var descriptor = DescriptorScript.new()
	descriptor.source_kind = source_kind
	return descriptor

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_zombie_multiplayer_wiring: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
