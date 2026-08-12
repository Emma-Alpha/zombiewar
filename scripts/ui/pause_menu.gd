class_name PauseMenu
extends Control

## 暂停菜单：ESC 呼出，提供「继续」与「返回大厅」。
## 单人局呼出时冻结游戏（process_mode 设为 ALWAYS 才能在暂停下接收输入）；
## 联机局只弹菜单不冻结（冻结会断 tick 同步）。

signal resume_requested
signal return_to_lobby_requested

@onready var resume_button: Button = %ResumeButton
@onready var lobby_button: Button = %LobbyButton

func _ready() -> void:
	# 必须 ALWAYS：单人局暂停后树是 paused，普通节点收不到输入也画不出来。
	process_mode = Node.PROCESS_MODE_ALWAYS
	hide()
	resume_button.pressed.connect(func() -> void: resume_requested.emit())
	lobby_button.pressed.connect(func() -> void: return_to_lobby_requested.emit())

func open() -> void:
	show()
	resume_button.grab_focus()

func close() -> void:
	hide()

func is_open() -> bool:
	return visible
