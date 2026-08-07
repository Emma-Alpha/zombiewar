extends Node
class_name PlayerRegistry

signal player_registered(player: PlayerController)
signal player_unregistered(player: PlayerController)

var players: Array[PlayerController] = []

func register_player(player: PlayerController) -> void:
	if player == null or players.has(player):
		return
	players.append(player)
	player.tree_exiting.connect(unregister_player.bind(player), CONNECT_ONE_SHOT)
	player_registered.emit(player)

func unregister_player(player: PlayerController) -> void:
	if not players.has(player):
		return
	players.erase(player)
	player_unregistered.emit(player)

func get_players() -> Array[PlayerController]:
	return players.duplicate()
