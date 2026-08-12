extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var scene := load("res://scenes/camera/FollowCamera.tscn") as PackedScene
	_expect(scene != null, "FollowCamera scene must load", failures)
	if scene == null:
		_finish(failures)
		return
	var follow = scene.instantiate()
	root.add_child(follow)
	await process_frame
	var visual_offset := follow.get_node_or_null("VisualOffset") as Node3D
	var camera := follow.get_node_or_null("VisualOffset/Camera3D") as Camera3D
	_expect(visual_offset != null, "FollowCamera must contain VisualOffset", failures)
	_expect(camera != null, "Camera3D must be a child of VisualOffset", failures)
	if camera != null:
		_expect(camera.projection == Camera3D.PROJECTION_ORTHOGONAL, "shared camera must remain orthogonal", failures)
		# e62dd06「随机掉落」把正交尺寸从 15 放宽到 18（掉落物要落在视野内），
		# 但漏改了这条断言，于是这个测试在 origin/main 上一直是红的。
		# 这里跟上场景的实际取值——一条永远失败的断言等于没有断言。
		_expect(is_equal_approx(camera.size, 18.0), "shared camera size must remain 18", failures)
		_expect(camera.position.is_equal_approx(Vector3(0.0, 12.0, 14.142136)), "camera local position and height must remain unchanged", failures)
		_expect(camera.rotation_degrees.is_equal_approx(Vector3(-40.3, 0.0, 0.0)), "camera rotation must remain unchanged", failures)
	_expect(follow.has_method("set_player_registry"), "FollowCamera must accept PlayerRegistry", failures)
	_expect(follow.has_method("set_world_bounds"), "FollowCamera must accept world bounds", failures)
	_expect(follow.has_method("get_anchor_position"), "FollowCamera must expose shared anchor position", failures)
	if visual_offset != null and follow.has_method("get_anchor_position"):
		var anchor_before: Vector3 = follow.get_anchor_position()
		var visual_before := visual_offset.position
		follow.add_shot_impulse(Vector3.RIGHT, 0.1)
		follow._physics_process(0.0)
		_expect(follow.get_anchor_position() == anchor_before, "shot impulse must not move shared camera anchor", failures)
		_expect(visual_offset.position != visual_before, "shot impulse must move only VisualOffset", failures)

	follow.queue_free()
	await process_frame

	var session = root.get_node("GameSession")
	session.configure_single()
	var arena_scene := load("res://scenes/maps/demo/DemoMap.tscn") as PackedScene
	var arena = arena_scene.instantiate()
	root.add_child(arena)
	await process_frame
	var arena_follow = arena.get_node("FollowCamera")
	var registry = arena.get_node("PlayerRegistry")
	var property_names: Array[StringName] = []
	for property in arena_follow.get_property_list():
		property_names.append(property["name"])
	_expect(property_names.has(&"player_registry"), "FollowCamera must retain injected registry", failures)
	if property_names.has(&"player_registry"):
		_expect(arena_follow.player_registry == registry, "GameplayArena must inject its PlayerRegistry into FollowCamera", failures)
	_expect(arena.get_node_or_null("FollowCamera/VisualOffset/Camera3D") != null, "GameplayArena consumers must use nested shared camera path", failures)
	arena.queue_free()
	await process_frame
	session.clear()
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_shared_camera_scene: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
