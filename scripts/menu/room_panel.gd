extends VBoxContainer
class_name RoomPanel

## 已入房时的那一屏：四张座位卡 + 地图卡 + 动作条。
##
## 它把服务端的座位表翻译成四张卡的状态，并把「我想换角色/换地图/准备/开局」
## 四种意图抛给大厅宿主。它不发网络消息，也不判断自己是不是房主——
## 房主是谁由传进来的 host_slot 决定，那是服务端的答案。

signal ready_toggled(is_ready: bool)
signal start_requested
signal character_step_requested(step: int)
signal map_selected(map_id: StringName)
signal back_requested

const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
## 弹层里的按钮是运行时 new 出来的，拿不到场景里那份字体覆盖。
## 项目没有全局主题字体，不显式指定就会回退到默认字体——中文在 Web 导出上
## 渲染成豆腐，而桌面端会被系统字体回退掩盖，这类 bug 装不出来。
const UI_FONT := preload("res://assets/fonts/NotoSansSC-UI.ttf")
const SEAT_COUNT := 4
const DISCONNECTED_SUFFIX := "（掉线）"

@onready var map_card: MapCard = %MapCard
@onready var ready_button: Button = %ReadyButton
@onready var start_button: Button = %StartButton
@onready var back_button: Button = %BackButton
@onready var map_popup: PopupPanel = %MapPopup
@onready var map_popup_list: VBoxContainer = %MapPopupList

var _cards: Array[SeatCard] = []
var _is_ready := false

func _ready() -> void:
	for index in range(SEAT_COUNT):
		var card := get_node("%%SeatCard%d" % index) as SeatCard
		_cards.append(card)
		card.character_step_requested.connect(_on_card_step)
	map_card.map_change_requested.connect(_on_map_change_requested)
	ready_button.pressed.connect(_on_ready_pressed)
	start_button.pressed.connect(func(): start_requested.emit())
	back_button.pressed.connect(func(): back_requested.emit())

## 把一份服务端座位表铺到四张卡上。
##
## players 是**稀疏**的——中间的人退了会留洞，服务端只在开局那一刻压实。
## 所以这里按 slot 索引铺，而不是按数组顺序铺：按顺序铺会让 P3 退房后
## P4 跳到 P3 的位置上，看起来像换了个人。
func apply_roster(
	players: Array,
	host_slot: int,
	state: String,
	local_slot: int,
	map_id: StringName
) -> void:
	var by_slot := {}
	for entry in players:
		if typeof(entry) == TYPE_DICTIONARY:
			by_slot[int(entry.get("slot", -1))] = entry
	var catalog = ContentCatalogsScript.characters()

	for index in range(SEAT_COUNT):
		var card := _cards[index]
		if not by_slot.has(index):
			card.set_empty()
			continue
		var entry: Dictionary = by_slot[index]
		var character = catalog.get_by_id(StringName(entry.get("character_id", "")))
		var is_local := index == local_slot
		var is_ready := bool(entry.get("ready", false))
		if is_local:
			_is_ready = is_ready
		var nickname := String(entry.get("nickname", ""))
		if not bool(entry.get("connected", true)):
			nickname += DISCONNECTED_SUFFIX
		card.set_occupied(nickname, character, is_ready, index == host_slot, is_local)

	var is_host := local_slot >= 0 and local_slot == host_slot
	map_card.set_map(ContentCatalogsScript.maps().get_by_id(map_id), is_host)

	ready_button.disabled = is_host
	ready_button.text = "取消准备" if _is_ready else "准备"
	# 客户端这半只是提示，真正的闸门在服务端 room_rules.allNonHostSeatsReady；
	# 两边都要有，否则玩家会一直点一个什么都不会发生的按钮。
	var everyone_else_ready := _all_guests_ready(by_slot, host_slot)
	start_button.disabled = not (is_host and state == "lobby" and everyone_else_ready)
	start_button.text = "开始对局" if is_host else "等待房主开局"

func _all_guests_ready(by_slot: Dictionary, host_slot: int) -> bool:
	if host_slot < 0:
		return false
	for slot in by_slot.keys():
		if int(slot) == host_slot:
			continue
		if not bool((by_slot[slot] as Dictionary).get("ready", false)):
			return false
	return true

func _on_ready_pressed() -> void:
	_is_ready = not _is_ready
	ready_button.text = "取消准备" if _is_ready else "准备"
	ready_toggled.emit(_is_ready)

func _on_card_step(step: int) -> void:
	character_step_requested.emit(step)

func _on_map_change_requested() -> void:
	for child in map_popup_list.get_children():
		child.queue_free()
	var maps = ContentCatalogsScript.maps()
	for definition in maps.entries:
		if definition == null:
			continue
		var button := Button.new()
		button.text = "%s · 难度 %d" % [definition.display_name, definition.difficulty]
		button.add_theme_font_override("font", UI_FONT)
		var chosen: StringName = definition.map_id
		button.pressed.connect(func():
			map_popup.hide()
			map_selected.emit(chosen)
		)
		map_popup_list.add_child(button)
	map_popup.popup_centered()
