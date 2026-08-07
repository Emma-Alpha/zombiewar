extends Node
class_name GameSessionState

enum Mode {
	SINGLE,
	LOCAL_MULTIPLAYER,
	ONLINE_MULTIPLAYER,
}

var mode := Mode.SINGLE
var local_players: Array = []
var last_error := ""

func configure_single() -> void:
	mode = Mode.SINGLE
	local_players.clear()
	last_error = ""

func configure_local(players: Array) -> void:
	mode = Mode.LOCAL_MULTIPLAYER
	local_players = players.duplicate()
	last_error = ""

func clear() -> void:
	configure_single()
