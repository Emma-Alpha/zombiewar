@tool
extends Node3D
class_name MapFixedItemSpawnMarker

@export var spawn_id: StringName
@export var pickup: PickupDefinition
@export_range(1, 9999, 1) var amount := 1
@export_range(0, 1000000, 1) var respawn_delay_ticks := 60
