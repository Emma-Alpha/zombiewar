extends "res://scripts/gameplay/place_item_service.gd"

var next_result := false
var request_count := 0
var last_direction := Vector3.ZERO

func request_place_item(
	_requester: CollisionObject3D,
	_origin: Vector3,
	direction: Vector3,
	_item_scene: PackedScene = null
) -> bool:
	request_count += 1
	last_direction = direction
	return next_result
