extends "res://scripts/player/equipment_item.gd"
class_name PlaceableEquipment

@export var display_name := "油桶"
@export_range(0, 999999, 1) var initial_count := 999
@export var item_scene: PackedScene
@export var placement_direction_scale := 1.0

var remaining_count := -1
var place_item_service
var requester: CharacterBody3D

func _ready() -> void:
	_ensure_count_initialized()

func bind_context(
	wielder: CharacterBody3D,
	_visual_root: Node3D,
	_functional_ray_origin: Marker3D
) -> void:
	requester = wielder
	_ensure_count_initialized()

func set_place_item_service(service) -> void:
	place_item_service = service

func set_use_input(_pressed: bool, just_pressed: bool, aim: Vector3) -> void:
	if not just_pressed or not is_available():
		return
	if place_item_service == null or item_scene == null:
		return
	var origin := Vector3.ZERO
	if requester != null and requester.is_inside_tree():
		origin = requester.global_position
	elif is_inside_tree():
		origin = global_position
	if place_item_service.request_place_item(requester, origin, aim * placement_direction_scale, item_scene):
		remaining_count -= 1
		count_changed.emit(remaining_count)

func is_available() -> bool:
	_ensure_count_initialized()
	return remaining_count > 0

func get_display_name() -> String:
	return display_name

func get_remaining_count() -> int:
	_ensure_count_initialized()
	return remaining_count

func _ensure_count_initialized() -> void:
	if remaining_count < 0:
		remaining_count = maxi(initial_count, 0)
