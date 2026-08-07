extends SceneTree

const SMG_SCENE_PATH := "res://scenes/weapons/Smg.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	var scene := load(SMG_SCENE_PATH) as PackedScene
	_expect(scene != null, "SMG scene must load", failures)
	if scene != null:
		var smg = scene.instantiate()
		var shot_audio := smg.get_node_or_null("ShotAudio") as AudioStreamPlayer3D
		_expect(shot_audio != null, "SMG must expose ShotAudio", failures)
		if shot_audio != null and shot_audio.stream != null:
			var attacks_per_second: float = smg.definition.attacks_per_second
			var required_voices := ceili(
				shot_audio.stream.get_length() * attacks_per_second
			)
			_expect(
				shot_audio.max_polyphony >= required_voices,
				"automatic fire audio must let each shot finish without cutting off its tail",
				failures
			)
		smg.free()
	_finish(failures)


func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_automatic_weapon_audio: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
