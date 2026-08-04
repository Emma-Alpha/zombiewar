extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const EquipmentController = preload("res://scripts/player/equipment_controller.gd")

var weapon_changed_emissions := 0

func run() -> Array[String]:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(player)
	var equipment := player.get_node_or_null("EquipmentController") as EquipmentController
	_append(failures, Assertions.expect_true(
		equipment != null,
		"Player owns an equipment controller"
	))
	if equipment == null:
		player.free()
		return failures

	_append(failures, Assertions.expect_equal(
		equipment.weapons.size(), 3, "Player loadout has pistol, rifle, and knife"
	))
	_append(failures, Assertions.expect_equal(
		equipment.get_current_definition().weapon_id,
		&"rifle",
		"Player starts with the rifle"
	))
	var rifle_visual := player.visual_root.find_child("Rifle", true, false) as Node3D
	var pistol_visual := player.visual_root.find_child("Pistol", true, false) as Node3D
	var knife_visual := player.visual_root.find_child("Knife", true, false) as Node3D
	_append(failures, Assertions.expect_true(
		rifle_visual != null and rifle_visual.visible,
		"Starting rifle visual is visible"
	))
	_append(failures, Assertions.expect_true(
		pistol_visual != null and not pistol_visual.visible,
		"Unequipped pistol visual is hidden"
	))
	weapon_changed_emissions = 0
	equipment.weapon_changed.connect(_on_weapon_changed)
	var starting_rifle := equipment.get_current_weapon()
	starting_rifle.set_attack_input(true, true, Vector3.FORWARD)
	_append(failures, Assertions.expect_true(
		equipment.equip_slot(1),
		"Selecting the current rifle slot succeeds"
	))
	_append(failures, Assertions.expect_true(
		equipment.get_current_weapon() == starting_rifle and
		starting_rifle.trigger_pressed and starting_rifle.trigger_just_pressed,
		"Selecting the current slot preserves the active weapon attack state"
	))
	_append(failures, Assertions.expect_equal(
		weapon_changed_emissions,
		0,
		"Selecting the current slot does not emit weapon_changed"
	))
	_append(failures, Assertions.expect_true(
		rifle_visual.visible and not pistol_visual.visible,
		"Selecting the current slot leaves weapon visuals unchanged"
	))

	_append(failures, Assertions.expect_true(
		equipment.equip_slot(0), "Pistol slot can be equipped"
	))
	_append(failures, Assertions.expect_equal(
		equipment.get_current_definition().weapon_id,
		&"pistol",
		"Equipping slot zero selects the pistol"
	))
	_append(failures, Assertions.expect_true(
		pistol_visual.visible and not rifle_visual.visible,
		"Equipping pistol swaps embedded weapon visuals"
	))
	_append(failures, Assertions.expect_equal(
		equipment.get_idle_animation(),
		&"Idle_Gun",
		"Pistol exposes gun idle animation"
	))
	_append(failures, Assertions.expect_true(
		equipment.equip_slot(2), "Knife slot can be equipped"
	))
	_append(failures, Assertions.expect_equal(
		equipment.get_current_definition().weapon_id,
		&"knife",
		"Third slot selects the knife"
	))
	_append(failures, Assertions.expect_equal(
		equipment.get_run_animation(),
		&"Run_Slash",
		"Knife exposes slash locomotion animation"
	))
	_append(failures, Assertions.expect_true(
		knife_visual != null and knife_visual.visible and
		not pistol_visual.visible and not rifle_visual.visible,
		"Equipping knife shows only the embedded knife visual"
	))
	_append(failures, Assertions.expect_true(
		not equipment.equip_slot(3),
		"Empty fourth slot is rejected"
	))
	_append(failures, Assertions.expect_equal(
		equipment.get_current_definition().weapon_id,
		&"knife",
		"Rejected fourth slot keeps the knife equipped"
	))
	player.free()
	return failures

func _on_weapon_changed(_definition: WeaponDefinition) -> void:
	weapon_changed_emissions += 1

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
