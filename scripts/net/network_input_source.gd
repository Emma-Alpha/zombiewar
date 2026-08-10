extends PlayerInputSource
class_name NetworkInputSource

## 远端玩家的输入源。它是 `PlayerInputSource` 的子类，所以 `LocalPlayerSpawner`、
## `PlayerController`、`EquipmentController` 对「联机玩家」一无所知——这正是本地
## 多人设计里写下的那条接缝：「后续网络玩家应能复用同一玩家输入边界」。
##
## 与本地输入源的关键差异：**不做边沿检测**。按下的那一帧由发端算好并打进
## 命令位里，收端再算一次就会把「按住」重新解释成「刚按下」，远端玩家于是
## 每 tick 都在换枪。所以这里直接构造状态，绕开 build_state()。

const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")
# PlayerInputStateScript 由父类 PlayerInputSource 提供，这里不再声明：
# 重复声明会遮蔽父类成员，GDScript 直接判定为编译错误。

var _state = PlayerInputStateScript.new()
var _present := false

func is_online() -> bool:
	return _present

func get_source_key() -> StringName:
	return &"network"

func sample():
	# 每 tick 消费一次：一次性的边沿位读完即清，否则一帧命令会被渲染帧
	# 重复采样多次，一次射击变成连发。
	var consumed = _state
	_state = PlayerInputStateScript.new()
	_state.move_vector = consumed.move_vector
	_state.use_pressed = consumed.use_pressed
	return consumed

## 由 DemoArena 在应用每一帧时调用。
func apply_command(command: Dictionary) -> void:
	var state = PlayerInputStateScript.new()
	state.move_vector = LobbyProtocolScript.command_move_vector(command)
	state.use_pressed = LobbyProtocolScript.command_has_bit(
		command, LobbyProtocolScript.BIT_USE_PRESSED
	)
	state.use_just_pressed = LobbyProtocolScript.command_has_bit(
		command, LobbyProtocolScript.BIT_USE_JUST_PRESSED
	)
	state.previous_equipment_just_pressed = LobbyProtocolScript.command_has_bit(
		command, LobbyProtocolScript.BIT_PREV_EQUIPMENT
	)
	state.next_equipment_just_pressed = LobbyProtocolScript.command_has_bit(
		command, LobbyProtocolScript.BIT_NEXT_EQUIPMENT
	)
	state.confirm_just_pressed = LobbyProtocolScript.command_has_bit(
		command, LobbyProtocolScript.BIT_CONFIRM
	)
	_state = state
	_present = LobbyProtocolScript.command_has_bit(
		command, LobbyProtocolScript.BIT_PRESENT
	)

## 座位空着或该玩家掉线时调用：远端角色停在原地而不是保持最后一次的移动。
func clear() -> void:
	_state = PlayerInputStateScript.new()
	_present = false
