extends PanelContainer
class_name SeatCard

## 一张座位卡。纯展示件——它不知道网络存在，只接受一份解析好的座位数据。
##
## 角色切换在这里只表达为「往前一个/往后一个」，由房间面板去查目录、发消息。
## 卡片自己去查目录的话，四张卡就有四份对「下一个角色是谁」的判断。

signal character_step_requested(step: int)

const EMPTY_TEXT := "等待玩家加入"
const EMPTY_RULE_COLOR := Color(0.28, 0.30, 0.32, 1.0)
const EMPTY_NAME_COLOR := Color(0.62, 0.65, 0.68, 1.0)

@onready var viewport_container: SubViewportContainer = %CharacterViewportContainer
@onready var preview = %LobbyPlayerPreview
@onready var name_label: Label = %NameLabel
@onready var host_badge: Label = %HostBadge
@onready var ready_banner: Label = %ReadyBanner
@onready var previous_button: Button = %PreviousButton
@onready var next_button: Button = %NextButton
@onready var accent_rule: ColorRect = %AccentRule

func _ready() -> void:
	previous_button.pressed.connect(func(): character_step_requested.emit(-1))
	next_button.pressed.connect(func(): character_step_requested.emit(1))
	preview.set_label_visible(false)
	set_empty()

func set_empty() -> void:
	viewport_container.visible = false
	name_label.text = EMPTY_TEXT
	name_label.modulate = EMPTY_NAME_COLOR
	host_badge.visible = false
	ready_banner.visible = false
	previous_button.visible = false
	next_button.visible = false
	accent_rule.color = EMPTY_RULE_COLOR

func set_occupied(
	nickname: String,
	character: CharacterDefinition,
	is_ready: bool,
	is_host: bool,
	is_local: bool
) -> void:
	viewport_container.visible = true
	name_label.text = nickname
	name_label.modulate = Color.WHITE
	host_badge.visible = is_host
	ready_banner.visible = is_ready
	# 准备之后锁定选择：别人是对着当前这套阵容点的准备。
	var can_switch := is_local and not is_ready
	previous_button.visible = can_switch
	next_button.visible = can_switch
	var accent := character.accent_color if character != null else Color.WHITE
	accent_rule.color = accent
	preview.set_accent_color(accent)
	preview.set_online(true)
	# 本机那张卡靠更亮的描边区分，不做单独的放大预览。
	self_modulate = Color(1.15, 1.15, 1.15, 1.0) if is_local else Color.WHITE
