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
	_test_double_blocked_ranged_equip_rejection(failures)
	return failures

func _test_double_blocked_ranged_equip_rejection(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var melee_player := PLAYER_SCENE.instantiate() as PlayerController
	var front_wall := _make_wall(
		Vector3(0.0, 1.12, -1.1),
		Vector3(3.0, 0.3, 0.2)
	)
	var low_ceiling := _make_wall(
		Vector3(0.0, 2.25, -0.25),
		Vector3(3.0, 0.2, 2.0)
	)
	tree.root.add_child(melee_player)
	var melee_equipment := melee_player.equipment
	var melee_collision := melee_player.get_node_or_null("WeaponCollision") as CollisionShape3D
	var melee_rifle := melee_equipment.weapons[1]
	var melee_knife := melee_equipment.weapons[2]
	melee_equipment.equip_slot(2)
	melee_knife.set_attack_input(true, true, Vector3.FORWARD)
	tree.root.add_child(front_wall)
	tree.root.add_child(low_ceiling)
	_append(failures, Assertions.expect_true(
		not melee_equipment.equip_slot(1),
		"Double-blocked rifle is rejected before it replaces an equipped knife"
	))
	_append(failures, Assertions.expect_true(
		melee_equipment.current_slot == 2 and
			melee_equipment.get_current_weapon() == melee_knife and
			melee_knife.visual_anchor.visible and not melee_rifle.visual_anchor.visible and
			melee_knife.trigger_pressed and melee_knife.trigger_just_pressed,
		"Rejected rifle preserves the knife slot, visibility, and attack state"
	))
	_append(failures, Assertions.expect_true(
		melee_collision != null and melee_collision.disabled,
		"Weapon collision stays disabled only because the preserved weapon is melee"
	))
	front_wall.free()
	low_ceiling.free()
	melee_player.free()

	var ranged_player := PLAYER_SCENE.instantiate() as PlayerController
	var ranged_front_wall := _make_wall(
		Vector3(0.0, 1.12, -1.1),
		Vector3(3.0, 0.3, 0.2)
	)
	var ranged_low_ceiling := _make_wall(
		Vector3(0.0, 2.25, -0.25),
		Vector3(3.0, 0.2, 2.0)
	)
	tree.root.add_child(ranged_player)
	var ranged_equipment := ranged_player.equipment
	var ranged_collision := ranged_player.get_node_or_null("WeaponCollision") as CollisionShape3D
	var pistol := ranged_equipment.weapons[0]
	var rifle := ranged_equipment.weapons[1]
	ranged_equipment.equip_slot(0)
	pistol.set_attack_input(true, true, Vector3.FORWARD)
	tree.root.add_child(ranged_front_wall)
	tree.root.add_child(ranged_low_ceiling)
	_append(failures, Assertions.expect_true(
		not ranged_equipment.equip_slot(1),
		"Double-blocked rifle is rejected before it replaces an equipped pistol"
	))
	_append(failures, Assertions.expect_true(
		ranged_equipment.current_slot == 0 and
			ranged_equipment.get_current_weapon() == pistol and
			pistol.visual_anchor.visible and not rifle.visual_anchor.visible and
			pistol.trigger_pressed and pistol.trigger_just_pressed and
			ranged_collision != null and not ranged_collision.disabled,
		"Rejected rifle keeps the active pistol collision enabled instead of disabling it"
	))
	ranged_front_wall.free()
	ranged_low_ceiling.free()
	ranged_player.free()

func _make_wall(position: Vector3, size: Vector3) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.position = position
	wall.collision_layer = 1
	wall.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	wall.add_child(collision)
	return wall

func _on_weapon_changed(_definition: WeaponDefinition) -> void:
	weapon_changed_emissions += 1

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
