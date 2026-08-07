extends Node3D
class_name SpatialSfxPool

const GROUP_NAME := &"spatial_sfx_pool"

@export_range(1, 64, 1) var capacity := 16

var players: Array[AudioStreamPlayer3D] = []
var cursor := 0


func _ready() -> void:
	for index in range(capacity):
		var player := AudioStreamPlayer3D.new()
		player.name = "Voice%02d" % (index + 1)
		add_child(player)
		players.append(player)


static func find_for(node: Node) -> SpatialSfxPool:
	if node == null or node.get_tree() == null:
		return null
	return node.get_tree().get_first_node_in_group(GROUP_NAME) as SpatialSfxPool


func play_at(
	stream: AudioStream,
	world_position: Vector3,
	volume_db := 0.0,
	pitch_scale := 1.0,
	max_distance := 32.0
) -> void:
	if stream == null or players.is_empty():
		return
	var player := players[cursor]
	cursor = (cursor + 1) % players.size()
	player.stop()
	player.stream = stream
	player.global_position = world_position
	player.volume_db = volume_db
	player.pitch_scale = pitch_scale
	player.max_distance = max_distance
	player.play()
