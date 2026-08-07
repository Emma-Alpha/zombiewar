extends Label3D
class_name PlayerEquipmentLabel

func set_status(player_index: int, display_name: String, count: int) -> void:
	text = "P%d · %s" % [player_index + 1, display_name]
	if count >= 0:
		text += " ×%d" % count
