extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var tree := Engine.get_main_loop() as SceneTree
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var wall := _make_wall(
		Vector3(-1.0, 1.0, 0.0),
		Vector3(0.2, 2.0, 3.0)
	)
	Input.action_release(player.primary_attack_action)
	tree.root.add_child(player)
	tree.root.add_child(wall)
	wall.force_update_transform()
	var start := player.global_position
	player.apply_damage(10.0, Vector3.RIGHT)
	for _frame in range(40):
		player._physics_process(1.0 / 60.0)
	var travel := player.global_position - start
	_append(failures, Assertions.expect_true(
		travel.x < -0.1,
		"Real knockback moves away from a right-side attacker"
	))
	_append(failures, Assertions.expect_true(
		player.global_position.x >= -0.46,
		"The player body stops at the wall instead of crossing it"
	))
	Input.action_release(player.primary_attack_action)
	wall.free()
	player.free()
	return failures

func _make_wall(position: Vector3, size: Vector3) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.position = position
	wall.collision_layer = 1
	wall.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	wall.add_child(collision)
	return wall

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
