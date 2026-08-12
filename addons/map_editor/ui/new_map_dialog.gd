@tool
extends ConfirmationDialog

signal request_ready(request: Dictionary)


func _ready() -> void:
	confirmed.connect(_on_confirmed)


func _on_confirmed() -> void:
	request_ready.emit({
		"map_id": StringName(%MapIdEdit.text.strip_edges()),
		"display_name": %DisplayNameEdit.text.strip_edges(),
		"grid_width": int(%GridWidthSpin.value),
		"grid_height": int(%GridHeightSpin.value),
		"grid_cell_size": float(%CellSizeSpin.value),
	})
