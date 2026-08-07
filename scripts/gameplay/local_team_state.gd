extends Node
class_name LocalTeamState

signal all_players_defeated

var players: Array[PlayerController] = []
var defeat_emitted := false

func setup(value: Array[PlayerController]) -> void:
	for player in players:
		if is_instance_valid(player) and player.died.is_connected(_on_player_died):
			player.died.disconnect(_on_player_died)
	players = value.duplicate()
	defeat_emitted = false
	for player in players:
		if not player.died.is_connected(_on_player_died):
			player.died.connect(_on_player_died)

func is_all_defeated() -> bool:
	return not players.is_empty() and players.all(
		func(player: PlayerController) -> bool: return not player.is_alive()
	)

func sample_restart_requested() -> bool:
	if not is_all_defeated() or players.is_empty():
		return false
	return players[0].get_last_input_state().confirm_just_pressed

func _on_player_died() -> void:
	if defeat_emitted or not is_all_defeated():
		return
	defeat_emitted = true
	all_players_defeated.emit()
