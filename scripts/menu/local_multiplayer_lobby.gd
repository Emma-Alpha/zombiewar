extends Node3D
class_name LocalMultiplayerLobby

const LocalPlayerJoinStateScript = preload(
	"res://scripts/menu/local_player_join_state.gd"
)
const LocalPlayerDescriptorScript = preload(
	"res://scripts/input/local_player_descriptor.gd"
)
const LOBBY_PLAYER_PREVIEW_SCENE := preload(
	"res://scenes/menu/LobbyPlayerPreview.tscn"
)

@export_file("*.tscn") var game_scene_path := "res://scenes/maps/demo/DemoMap.tscn"
@export_file("*.tscn") var main_menu_scene_path := "res://scenes/menu/MainMenu.tscn"

@onready var warning_light: OmniLight3D = $WarningLight
@onready var camera: Camera3D = $Camera3D
@onready var title: Label = $MenuLayer/Title
@onready var join_hint: Label = $MenuLayer/JoinHint
@onready var status_root: HBoxContainer = $MenuLayer/StatusRoot
@onready var p1_hint: Label = $MenuLayer/P1Hint

var join_state = LocalPlayerJoinStateScript.new()
var transition_pending := false
var slot_previews: Dictionary = {}
var _elapsed := 0.0
var _base_light_energy := 5.0
var _base_camera_position := Vector3.ZERO

func _ready() -> void:
	_base_light_energy = warning_light.light_energy
	_base_camera_position = camera.position
	MenuEntrance.play(self, [title, join_hint, status_root, p1_hint], 0)
	if not Input.joy_connection_changed.is_connected(_on_joy_connection_changed):
		Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_sync_slots()

func _process(delta: float) -> void:
	_elapsed += delta
	# 与主菜单同一套警戒灯语言：慢扫 + 闪烁，让座位区一直「待命」。
	var sweep := sin(_elapsed * 1.9) * 0.5
	var flicker := sin(_elapsed * 8.7) * sin(_elapsed * 3.3) * 0.4
	warning_light.light_energy = _base_light_energy + sweep + flicker
	# 镜头极轻地呼吸，画面不僵住。
	camera.position = _base_camera_position + Vector3(
		sin(_elapsed * 0.16) * 0.12, sin(_elapsed * 0.21) * 0.06, 0.0
	)

func _exit_tree() -> void:
	if Input.joy_connection_changed.is_connected(_on_joy_connection_changed):
		Input.joy_connection_changed.disconnect(_on_joy_connection_changed)

func _input(event: InputEvent) -> void:
	if transition_pending:
		return
	if event is InputEventKey:
		_handle_key(event as InputEventKey)
	elif event is InputEventJoypadButton:
		_handle_joypad_button(event as InputEventJoypadButton)

func _handle_key(event: InputEventKey) -> void:
	if not event.pressed or event.echo:
		return
	var key := event.physical_keycode if event.physical_keycode != 0 else event.keycode
	if key == KEY_ESCAPE:
		_return_to_menu()
		return
	if key == KEY_ENTER and _p1_is_keyboard() and _p1_can_start():
		_start_local_game()
		return
	if key in [KEY_W, KEY_A, KEY_S, KEY_D]:
		_try_join(LocalPlayerDescriptorScript.SourceKind.KEYBOARD_WASD)
	elif key in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT]:
		_try_join(LocalPlayerDescriptorScript.SourceKind.KEYBOARD_ARROWS)

func _handle_joypad_button(event: InputEventJoypadButton) -> void:
	if not event.pressed:
		return
	if event.button_index == JOY_BUTTON_A:
		if _p1_is_gamepad(event.device) and _p1_can_start():
			_start_local_game()
		else:
			_try_join(LocalPlayerDescriptorScript.SourceKind.GAMEPAD, event.device)
		return
	if not _p1_is_gamepad(event.device):
		return
	if event.button_index == JOY_BUTTON_START and _p1_can_start():
		_start_local_game()
	elif event.button_index == JOY_BUTTON_B:
		_return_to_menu()

func _try_join(source_kind: int, device_id: int = -1) -> void:
	if join_state.try_join(source_kind, device_id) >= 0:
		_sync_slots()

func _p1_is_keyboard() -> bool:
	if join_state.players.is_empty():
		return false
	return join_state.players[0].source_kind in [
		LocalPlayerDescriptorScript.SourceKind.KEYBOARD_WASD,
		LocalPlayerDescriptorScript.SourceKind.KEYBOARD_ARROWS,
	]

func _p1_is_gamepad(device_id: int) -> bool:
	if join_state.players.is_empty():
		return false
	var player = join_state.players[0]
	return (
		player.source_kind == LocalPlayerDescriptorScript.SourceKind.GAMEPAD and
		player.gamepad_device_id == device_id
	)

func _p1_can_start() -> bool:
	return not join_state.players.is_empty() and join_state.players[0].online

func _start_local_game() -> void:
	if not _p1_can_start():
		return
	transition_pending = true
	GameSession.configure_local(join_state.players)
	get_tree().change_scene_to_file(game_scene_path)

func _return_to_menu() -> void:
	transition_pending = true
	GameSession.clear()
	get_tree().change_scene_to_file(main_menu_scene_path)

func _on_joy_connection_changed(device_id: int, connected: bool) -> void:
	join_state.set_gamepad_online(device_id, connected)
	_sync_slots()

func _sync_slots() -> void:
	for index in range(4):
		var label := get_node_or_null(
			"MenuLayer/StatusRoot/P%dStatus" % (index + 1)
		) as Label
		if label == null:
			continue
		if index >= join_state.players.size():
			label.text = "P%d · 等待加入" % (index + 1)
			_sync_slot_preview(index, null)
			continue
		var descriptor = join_state.players[index]
		_sync_slot_preview(index, descriptor)
		var source_name := _source_display_name(descriptor)
		label.text = "P%d · %s" % [index + 1, source_name]
		if not descriptor.online:
			label.text += " · 设备离线"
	var hint := get_node_or_null("MenuLayer/P1Hint") as Label
	if hint != null:
		hint.text = _p1_hint_text()

func _p1_hint_text() -> String:
	if join_state.players.is_empty():
		return "按 WASD / 方向键 / A 加入"
	if not join_state.players[0].online:
		return "P1 设备离线 · 等待恢复"
	if _p1_is_keyboard():
		return "P1：ENTER 开始 · ESC 返回"
	return "P1：A / START 开始 · B 返回"

func _sync_slot_preview(index: int, descriptor) -> void:
	var marker := get_node_or_null(
		"LobbyWorld/Slots/P%d" % (index + 1)
	) as Marker3D
	if marker == null:
		return
	if descriptor == null:
		if slot_previews.has(index):
			var old_preview = slot_previews[index]
			slot_previews.erase(index)
			if is_instance_valid(old_preview):
				marker.remove_child(old_preview)
				old_preview.queue_free()
		return
	var preview = slot_previews.get(index)
	if not is_instance_valid(preview):
		preview = LOBBY_PLAYER_PREVIEW_SCENE.instantiate()
		preview.name = "LobbyPlayerPreview"
		marker.add_child(preview)
		slot_previews[index] = preview
	preview.set_player_index(index)
	preview.set_online(descriptor.online)

func _source_display_name(descriptor) -> String:
	match descriptor.source_kind:
		LocalPlayerDescriptorScript.SourceKind.KEYBOARD_WASD:
			return "键盘 WASD"
		LocalPlayerDescriptorScript.SourceKind.KEYBOARD_ARROWS:
			return "键盘 方向键"
		LocalPlayerDescriptorScript.SourceKind.GAMEPAD:
			return "手柄 %d" % descriptor.gamepad_device_id
		_:
			return "未知设备"
