extends Node3D

const MenuFlow = preload("res://scripts/menu/menu_flow.gd")

@export_file("*.tscn") var game_scene_path := "res://scenes/maps/demo/DemoMap.tscn"
@export_file("*.tscn") var local_lobby_scene_path := "res://scenes/menu/LocalMultiplayerLobby.tscn"
@export_file("*.tscn") var online_lobby_scene_path := "res://scenes/menu/OnlineLobby.tscn"
@export_file("*.tscn") var leaderboard_scene_path := "res://scenes/menu/LeaderboardPanel.tscn"

@onready var single_player_button: Button = %SinglePlayerButton
@onready var local_multiplayer_button: Button = %LocalMultiplayerButton
@onready var online_multiplayer_button: Button = %OnlineMultiplayerButton
@onready var leaderboard_button: Button = %LeaderboardButton
@onready var quit_button: Button = %QuitButton
@onready var exit_dialog: Control = %ExitDialog
@onready var confirm_exit_button: Button = %ConfirmExitButton
@onready var fade_overlay: ColorRect = %FadeOverlay
@onready var select_audio: AudioStreamPlayer = $SelectAudio
@onready var confirm_audio: AudioStreamPlayer = $ConfirmAudio
@onready var back_audio: AudioStreamPlayer = $BackAudio
@onready var eyebrow: Label = %Eyebrow
@onready var title: Label = %Title
@onready var red_rule: ColorRect = %RedRule
@onready var subtitle: Label = %Subtitle
@onready var footer_hint: Label = %FooterHint
@onready var version_label: Label = %VersionLabel

var flow := MenuFlow.new()

func _ready() -> void:
	single_player_button.grab_focus()
	_play_boot_sequence()

## The menu opens like a boot sequence: each element wipes in from the left,
## staggered, so the composition assembles instead of just appearing.
func _play_boot_sequence() -> void:
	MenuEntrance.play(self, _entrance_elements(), 1)
	_breathe_title()

func _entrance_elements() -> Array:
	return [
		eyebrow, title, red_rule, subtitle,
		single_player_button, local_multiplayer_button,
		online_multiplayer_button, leaderboard_button, quit_button,
		footer_hint, version_label,
	]

func _breathe_title() -> void:
	# A faint warm pulse keeps the headline alive against the dark backdrop.
	var pulse := create_tween().set_loops()
	pulse.tween_property(title, "modulate", Color(1.0, 0.94, 0.9, 1.0), 2.6) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	pulse.tween_property(title, "modulate", Color(1.0, 1.0, 1.0, 1.0), 2.6) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

func _unhandled_input(event: InputEvent) -> void:
	var joy_button := event as InputEventJoypadButton
	var joy_a_pressed := (
		joy_button != null and joy_button.pressed and
		joy_button.button_index == JOY_BUTTON_A
	)
	var joy_b_pressed := (
		joy_button != null and joy_button.pressed and
		joy_button.button_index == JOY_BUTTON_B
	)
	if (
		(event.is_action_pressed("ui_cancel") or joy_b_pressed) and
		flow.state == MenuFlow.State.EXIT_CONFIRM
	):
		_on_cancel_exit_button_pressed()
		get_viewport().set_input_as_handled()
	elif joy_a_pressed and _activate_focused_button():
		get_viewport().set_input_as_handled()

func _activate_focused_button() -> bool:
	var focused_button := get_viewport().gui_get_focus_owner() as Button
	if focused_button == null or focused_button.disabled:
		return false
	focused_button.pressed.emit()
	return true

func _on_single_player_button_pressed() -> void:
	if not flow.request_single():
		return
	GameSession.configure_single()
	_start_transition(game_scene_path)

func _on_local_multiplayer_button_pressed() -> void:
	if not flow.request_local():
		return
	GameSession.clear()
	_start_transition(local_lobby_scene_path)

func _on_online_multiplayer_button_pressed() -> void:
	if not flow.request_local():
		return
	GameSession.clear()
	_start_transition(online_lobby_scene_path)

## 排行榜是只读页面，不开局，所以它不走 MenuFlow 的 STARTING 状态：
## 走了的话从排行榜返回主菜单后所有按钮都会卡在禁用状态。
func _on_leaderboard_button_pressed() -> void:
	if flow.state != MenuFlow.State.READY:
		return
	confirm_audio.play()
	get_tree().change_scene_to_file(leaderboard_scene_path)

func _start_transition(scene_path: String) -> void:
	confirm_audio.play()
	single_player_button.disabled = true
	local_multiplayer_button.disabled = true
	online_multiplayer_button.disabled = true
	leaderboard_button.disabled = true
	quit_button.disabled = true
	var tween := create_tween()
	tween.tween_property(fade_overlay, "color:a", 1.0, 0.32)
	await tween.finished
	get_tree().change_scene_to_file(scene_path)

func _on_quit_button_pressed() -> void:
	if not flow.request_exit():
		return
	confirm_audio.play()
	exit_dialog.show()
	confirm_exit_button.grab_focus()

func _on_confirm_exit_button_pressed() -> void:
	if flow.confirm_exit():
		get_tree().quit()

func _on_cancel_exit_button_pressed() -> void:
	if not flow.cancel_exit():
		return
	back_audio.play()
	exit_dialog.hide()
	quit_button.grab_focus()

func _on_action_focused() -> void:
	if not select_audio.playing:
		select_audio.play()
