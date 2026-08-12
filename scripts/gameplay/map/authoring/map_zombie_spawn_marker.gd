@tool
extends Node3D
class_name MapZombieSpawnMarker

@export var spawn_id: StringName
@export_range(0.0, 8.0, 0.05) var spawn_radius := 1.75
@export_range(0.0, 4.0, 0.05) var minimum_spacing := 1.1
