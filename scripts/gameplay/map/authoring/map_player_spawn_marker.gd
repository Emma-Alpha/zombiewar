@tool
extends Node3D
class_name MapPlayerSpawnMarker

@export var marker_id: StringName
@export_range(0, 3, 1) var slot_index := 0
