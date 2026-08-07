extends Label3D
class_name PlayerEquipmentLabel

func set_status(
	player_index: int,
	display_name: String,
	count_text: String
) -> void:
	text = "P%d · %s" % [player_index + 1, display_name]
	if not count_text.is_empty():
		text += ":%s" % count_text
