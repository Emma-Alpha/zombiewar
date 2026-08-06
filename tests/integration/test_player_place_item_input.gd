extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var requests: Array[Dictionary] = []
	player.place_item_requested.connect(
		Callable(self, "_capture_request").bind(requests)
	)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(player)
	player.set_physics_process(false)
	Input.action_release(&"place_item")
	Input.action_press(&"place_item")
	player._physics_process(0.0)
	player._physics_process(0.0)
	Input.action_release(&"place_item")
	_append(failures, Assertions.expect_equal(
		requests.size(),
		1,
		"One held place-item press emits one player request"
	))
	if requests.size() == 1:
		_append(failures, Assertions.expect_true(
			requests[0]["requester"] == player and
			requests[0]["origin"] == player.global_position and
			(requests[0]["direction"] as Vector3).is_equal_approx(Vector3.FORWARD),
			"Player request carries the player, origin, and current facing"
		))
	player.free()
	return failures

func _capture_request(
	requester: CollisionObject3D,
	origin: Vector3,
	direction: Vector3,
	requests: Array[Dictionary]
) -> void:
	requests.append({
		"requester": requester,
		"origin": origin,
		"direction": direction,
	})

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
