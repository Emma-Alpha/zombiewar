extends SceneTree

const PREVIEW_SCENE_PATH := "res://scenes/menu/LobbyPlayerPreview.tscn"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(ResourceLoader.exists(PREVIEW_SCENE_PATH), "LobbyPlayerPreview scene must exist", failures)
	if not failures.is_empty():
		_finish(failures)
		return

	var scene := load(PREVIEW_SCENE_PATH) as PackedScene
	var preview = scene.instantiate()
	root.add_child(preview)
	await process_frame
	var character_model := preview.get_node_or_null("ModelAnchor/CharacterModel")
	_expect(character_model != null, "preview must instantiate the real character GLTF", failures)
	if character_model != null:
		_expect(character_model.scene_file_path == "res://assets/characters/Characters_Lis_SingleWeapon.gltf", "preview character must come from the approved GLTF", failures)
		_expect(character_model.find_child("AnimationPlayer", true, false) is AnimationPlayer, "real character preview must contain AnimationPlayer", failures)
		var smg := character_model.find_child("SMG", true, false) as Node3D
		_expect(smg != null and smg.visible, "preview must show SMG", failures)
		for hidden_weapon in ["Axe", "Guitar", "Knife", "Pistol", "Ri" + "fle", "Shotgun", "Spear", "WoodenBat_Barbed", "WoodenBat_Saw"]:
			var weapon := character_model.find_child(hidden_weapon, true, false) as Node3D
			_expect(weapon == null or not weapon.visible, "%s must be hidden in lobby preview" % hidden_weapon, failures)

	_expect(preview.find_children("*", "CollisionShape3D", true, false).is_empty(), "preview must not contain collision shapes", failures)
	_expect(preview.find_child("EquipmentController", true, false) == null, "preview must not contain EquipmentController", failures)
	_expect(preview.find_child("HealthBar3D", true, false) == null, "preview must not contain HealthBar3D", failures)
	preview.set_player_index(1)
	_expect((preview.get_node("PlayerLabel") as Label3D).text == "P2", "preview must display its player number", failures)
	var light := preview.get_node("PlayerLight") as OmniLight3D
	var online_energy := light.light_energy
	preview.set_online(false)
	_expect(light.light_energy < online_energy, "offline preview must be visibly dimmer", failures)
	preview.queue_free()
	await process_frame

	var lobby_scene := load("res://scenes/menu/LocalMultiplayerLobby.tscn") as PackedScene
	var lobby = lobby_scene.instantiate()
	root.add_child(lobby)
	await process_frame
	_expect(lobby.get_node_or_null("LobbyWorld/Slots/P1/LobbyPlayerPreview") == null, "empty lobby slot must not contain a character preview", failures)
	lobby.join_state.try_join(0)
	lobby._sync_slots()
	_expect(lobby.get_node_or_null("LobbyWorld/Slots/P1/LobbyPlayerPreview") != null, "joined lobby slot must instantiate a character preview", failures)
	lobby.queue_free()
	await process_frame

	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_lobby_player_preview: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
