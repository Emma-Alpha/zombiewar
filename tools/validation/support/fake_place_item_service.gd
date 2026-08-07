extends "res://scripts/gameplay/place_item_service.gd"

var next_result := false
var request_count := 0

func request_place_item(
	_requester: CollisionObject3D,
	_origin: Vector3,
	_direction: Vector3,
	_item_scene: PackedScene = null
) -> bool:
	request_count += 1
	return next_result
