extends Node3D

const MenuFlow = preload("res://scripts/menu/menu_flow.gd")

@export_file("*.tscn") var game_scene_path := "res://scenes/gameplay/DemoArena.tscn"

@onready var start_button: Button = %StartButton
@onready var quit_button: Button = %QuitButton
@onready var exit_dialog: Control = %ExitDialog
@onready var confirm_exit_button: Button = %ConfirmExitButton
@onready var fade_overlay: ColorRect = %FadeOverlay
@onready var select_audio: AudioStreamPlayer = $SelectAudio
@onready var confirm_audio: AudioStreamPlayer = $ConfirmAudio
@onready var back_audio: AudioStreamPlayer = $BackAudio

var flow := MenuFlow.new()

func _ready() -> void:
	start_button.grab_focus()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and flow.state == MenuFlow.State.EXIT_CONFIRM:
		_on_cancel_exit_button_pressed()
		get_viewport().set_input_as_handled()

func _on_start_button_pressed() -> void:
	if not flow.request_start():
		return
	confirm_audio.play()
	start_button.disabled = true
	quit_button.disabled = true
	var tween := create_tween()
	tween.tween_property(fade_overlay, "color:a", 1.0, 0.32)
	await tween.finished
	get_tree().change_scene_to_file(game_scene_path)

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
