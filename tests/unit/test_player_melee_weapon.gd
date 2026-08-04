extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const TARGET_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")
const MeleeWeapon = preload("res://scripts/combat/weapons/melee_weapon.gd")

var melee_attack_started_emissions := 0

func run() -> Array[String]:
	var failures: Array[String] = []
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var front_target := TARGET_SCENE.instantiate() as ZombieTarget
	var farther_front_target := TARGET_SCENE.instantiate() as ZombieTarget
	var rear_target := TARGET_SCENE.instantiate() as ZombieTarget
	player.position = Vector3.ZERO
	front_target.position = Vector3(0.0, 0.0, -0.9)
	farther_front_target.position = Vector3(0.0, 0.0, -1.25)
	rear_target.position = Vector3(0.0, 0.0, 0.9)
	tree.root.add_child(host)
	host.add_child(player)
	host.add_child(front_target)
	host.add_child(farther_front_target)
	host.add_child(rear_target)

	var equipment := player.get_node("EquipmentController") as EquipmentController
	_append(failures, Assertions.expect_true(
		equipment.equip_slot(2), "Knife slot can be equipped"
	))
	var knife := equipment.get_current_weapon() as MeleeWeapon
	_append(failures, Assertions.expect_true(knife != null, "Knife uses melee runtime"))
	if knife == null:
		host.free()
		return failures
	knife.set_physics_process(false)

	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.0)
	_append(failures, Assertions.expect_float_near(
		front_target.health.current,
		50.0,
		0.0001,
		"Knife press starts animation without immediate damage"
	))
	_append(failures, Assertions.expect_true(
		player.attack_animation_remaining > 0.0,
		"Knife attack locks locomotion animation"
	))
	_append(failures, Assertions.expect_equal(
		player.animation_player.current_animation,
		&"Slash",
		"Knife plays Slash animation"
	))
	player._process(0.54)
	player._update_animation(12.0)
	_append(failures, Assertions.expect_equal(
		player.animation_player.current_animation,
		&"Slash",
		"Knife Slash is not overwritten during the 0.55 second attack lock"
	))
	_append(failures, Assertions.expect_true(
		player.attack_animation_remaining > 0.0,
		"Knife animation lock remains active before 0.55 seconds"
	))

	knife._physics_process(0.21)
	_append(failures, Assertions.expect_float_near(
		front_target.health.current,
		50.0,
		0.0001,
		"Knife does not damage before impact time"
	))
	knife._physics_process(0.01)
	_append(failures, Assertions.expect_float_near(
		front_target.health.current,
		15.0,
		0.0001,
		"Knife damages the closest forward target once"
	))
	_append(failures, Assertions.expect_float_near(
		farther_front_target.health.current,
		50.0,
		0.0001,
		"Knife does not damage a farther forward target"
	))
	_append(failures, Assertions.expect_float_near(
		rear_target.health.current,
		50.0,
		0.0001,
		"Knife does not damage a target behind the player"
	))
	knife._physics_process(0.20)
	_append(failures, Assertions.expect_float_near(
		front_target.health.current,
		15.0,
		0.0001,
		"Knife attack cannot damage the same target twice"
	))

	knife.cancel_attack()
	_append(failures, Assertions.expect_true(
		not knife.attack_pending,
		"Cancelling knife clears pending impact"
	))
	_test_attack_interruptions(failures, player, equipment, knife, front_target)
	host.free()
	_test_hit_reaction_blocks_new_attack(failures)
	_test_weapon_switch_preserves_cooldown(failures)
	_test_damage_clears_buffered_attack(failures)
	_test_weapon_switch_clears_buffered_attack(failures)
	_test_dense_hitboxes_choose_closest_target(failures)
	_test_body_hitbox_overlap_ignores_rear_target(failures)
	_test_knife_preserves_legacy_forward_reach(failures)
	return failures

func _test_attack_interruptions(
	failures: Array[String],
	player: PlayerController,
	equipment: EquipmentController,
	knife: MeleeWeapon,
	target: ZombieTarget
) -> void:
	knife.weapon_trigger.reset()
	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.0)
	player.apply_damage(1.0)
	knife._physics_process(0.22)
	_append(failures, Assertions.expect_true(
		not knife.attack_pending and target.health.current == 15.0,
		"Taking damage cancels a pending knife impact"
	))

	knife.weapon_trigger.reset()
	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.0)
	_append(failures, Assertions.expect_true(
		equipment.equip_slot(0), "Switching away from knife succeeds"
	))
	knife._physics_process(0.22)
	_append(failures, Assertions.expect_true(
		not knife.attack_pending and target.health.current == 15.0,
		"Switching weapons cancels a pending knife impact"
	))

	equipment.equip_slot(2)
	knife.weapon_trigger.reset()
	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.0)
	player.apply_damage(1000.0)
	knife._physics_process(0.22)
	_append(failures, Assertions.expect_true(
		not knife.attack_pending and target.health.current == 15.0,
		"Player death cancels a pending knife impact"
	))

func _test_hit_reaction_blocks_new_attack(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var target := TARGET_SCENE.instantiate() as ZombieTarget
	target.position = Vector3(0.0, 0.0, -0.9)
	tree.root.add_child(host)
	host.add_child(player)
	host.add_child(target)
	var equipment := player.get_node("EquipmentController") as EquipmentController
	equipment.equip_slot(2)
	var knife := equipment.get_current_weapon() as MeleeWeapon
	knife.set_physics_process(false)

	player.apply_damage(1.0)
	Input.action_press(player.primary_attack_action)
	player._physics_process(0.0)
	Input.action_release(player.primary_attack_action)
	knife._physics_process(0.0)
	_append(failures, Assertions.expect_true(
		not knife.attack_pending,
		"HitReact blocks a new knife attack from starting"
	))
	_append(failures, Assertions.expect_equal(
		player.animation_player.current_animation,
		&"HitReact",
		"HitReact cannot be overwritten by Slash"
	))
	knife._physics_process(0.22)
	_append(failures, Assertions.expect_float_near(
		target.health.current,
		50.0,
		0.0001,
		"Blocked HitReact attack leaves no delayed knife damage"
	))

	player._process(player.hit_reaction_duration)
	Input.action_press(player.primary_attack_action)
	player._physics_process(0.0)
	Input.action_release(player.primary_attack_action)
	knife._physics_process(0.0)
	_append(failures, Assertions.expect_true(
		knife.attack_pending,
		"Knife can start after HitReact finishes"
	))
	_append(failures, Assertions.expect_equal(
		player.animation_player.current_animation,
		&"Slash",
		"Slash plays after HitReact finishes"
	))
	host.free()

func _test_weapon_switch_preserves_cooldown(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var player := PLAYER_SCENE.instantiate() as PlayerController
	tree.root.add_child(player)
	var equipment := player.get_node("EquipmentController") as EquipmentController
	equipment.equip_slot(2)
	var knife := equipment.get_current_weapon() as MeleeWeapon
	knife.set_physics_process(false)
	melee_attack_started_emissions = 0
	knife.attack_started.connect(_on_melee_attack_started)

	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.0)
	equipment.equip_slot(0)
	equipment.equip_slot(2)
	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.0)
	_append(failures, Assertions.expect_equal(
		melee_attack_started_emissions,
		1,
		"Switching away and back cannot bypass knife cooldown"
	))
	if knife.attack_pending:
		knife.cancel_attack()

	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.65)
	_append(failures, Assertions.expect_equal(
		melee_attack_started_emissions,
		1,
		"Knife cannot restart before the 1.5 attacks-per-second cooldown"
	))
	if knife.attack_pending:
		knife.cancel_attack()

	equipment.set_attack_input(false, false, Vector3.FORWARD)
	knife._physics_process(0.02)
	_append(failures, Assertions.expect_equal(
		melee_attack_started_emissions,
		2,
		"Knife can restart when its cooldown finishes"
	))
	player.free()

func _test_damage_clears_buffered_attack(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var target := TARGET_SCENE.instantiate() as ZombieTarget
	target.position = Vector3(0.0, 0.0, -0.9)
	tree.root.add_child(host)
	host.add_child(player)
	host.add_child(target)
	var equipment := player.get_node("EquipmentController") as EquipmentController
	equipment.equip_slot(2)
	var knife := equipment.get_current_weapon() as MeleeWeapon
	knife.set_physics_process(false)
	melee_attack_started_emissions = 0
	knife.attack_started.connect(_on_melee_attack_started)

	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.0)
	knife._physics_process(0.60)
	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.02)
	player.apply_damage(1.0)
	equipment.set_attack_input(false, false, Vector3.FORWARD)
	knife._physics_process(0.05)
	_append(failures, Assertions.expect_equal(
		melee_attack_started_emissions,
		1,
		"Taking damage clears a buffered knife attack without firing it"
	))
	_append(failures, Assertions.expect_true(
		not knife.attack_pending,
		"Taking damage leaves no buffered knife pending during HitReact"
	))
	knife._physics_process(0.22)
	_append(failures, Assertions.expect_float_near(
		target.health.current,
		15.0,
		0.0001,
		"Cancelled damage buffer cannot cause delayed knife damage"
	))

	player._process(player.hit_reaction_duration)
	Input.action_press(player.primary_attack_action)
	player._physics_process(0.0)
	Input.action_release(player.primary_attack_action)
	knife._physics_process(0.0)
	_append(failures, Assertions.expect_true(
		melee_attack_started_emissions == 2 and knife.attack_pending,
		"A new player attack works after damage clears the old buffer"
	))
	host.free()

func _test_weapon_switch_clears_buffered_attack(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var target := TARGET_SCENE.instantiate() as ZombieTarget
	target.position = Vector3(0.0, 0.0, -0.9)
	tree.root.add_child(host)
	host.add_child(player)
	host.add_child(target)
	var equipment := player.get_node("EquipmentController") as EquipmentController
	equipment.equip_slot(2)
	var knife := equipment.get_current_weapon() as MeleeWeapon
	knife.set_physics_process(false)
	melee_attack_started_emissions = 0
	knife.attack_started.connect(_on_melee_attack_started)

	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.0)
	knife._physics_process(0.60)
	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.02)
	equipment.equip_slot(0)
	equipment.equip_slot(2)
	equipment.set_attack_input(false, false, Vector3.FORWARD)
	knife._physics_process(0.05)
	_append(failures, Assertions.expect_equal(
		melee_attack_started_emissions,
		1,
		"Switching weapons clears a buffered knife attack without firing it"
	))
	_append(failures, Assertions.expect_true(
		not knife.attack_pending,
		"Switching away and back leaves no buffered knife pending"
	))
	knife._physics_process(0.22)
	_append(failures, Assertions.expect_float_near(
		target.health.current,
		15.0,
		0.0001,
		"Cancelled switch buffer cannot cause delayed knife damage"
	))

	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.0)
	_append(failures, Assertions.expect_true(
		melee_attack_started_emissions == 2 and knife.attack_pending,
		"A new attack works after weapon switching clears the old buffer"
	))
	host.free()

func _test_dense_hitboxes_choose_closest_target(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var far_target := TARGET_SCENE.instantiate() as ZombieTarget
	far_target.position = Vector3(0.0, 0.0, -1.2)
	for index in range(20):
		var extra_hitbox := Area3D.new()
		extra_hitbox.name = "ExtraHitbox%d" % index
		extra_hitbox.position = Vector3(0.7, 1.0, 0.95)
		extra_hitbox.collision_layer = 4
		extra_hitbox.collision_mask = 0
		extra_hitbox.monitoring = false
		var collision_shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.2, 0.2, 0.2)
		collision_shape.shape = box
		extra_hitbox.add_child(collision_shape)
		far_target.add_child(extra_hitbox)
	var closest_target := TARGET_SCENE.instantiate() as ZombieTarget
	closest_target.position = Vector3(-0.7, 0.0, -0.25)
	for hitbox in closest_target.get_node("Hitboxes").get_children():
		if hitbox.name != "BodyHitbox":
			(hitbox as Area3D).collision_layer = 0
	tree.root.add_child(host)
	host.add_child(player)
	host.add_child(far_target)
	host.add_child(closest_target)
	var equipment := player.get_node("EquipmentController") as EquipmentController
	equipment.equip_slot(2)
	var knife := equipment.get_current_weapon() as MeleeWeapon
	knife.set_physics_process(false)

	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.0)
	knife._physics_process(0.22)
	_append(failures, Assertions.expect_float_near(
		closest_target.health.current,
		15.0,
		0.0001,
		"Knife selects the closest target beyond sixteen overlapping Areas"
	))
	_append(failures, Assertions.expect_float_near(
		far_target.health.current,
		50.0,
		0.0001,
		"Dense farther hitboxes do not hide the closest target"
	))
	host.free()

func _test_body_hitbox_overlap_ignores_rear_target(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var rear_target := TARGET_SCENE.instantiate() as ZombieTarget
	rear_target.position = Vector3(0.0, 0.0, 0.9)
	tree.root.add_child(host)
	host.add_child(player)
	host.add_child(rear_target)
	var equipment := player.get_node("EquipmentController") as EquipmentController
	equipment.equip_slot(2)
	var knife := equipment.get_current_weapon() as MeleeWeapon
	knife.set_physics_process(false)

	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.0)
	knife._physics_process(0.22)
	_append(failures, Assertions.expect_float_near(
		rear_target.health.current,
		50.0,
		0.0001,
		"Rear target is ignored when its enlarged body cylinder overlaps the melee box"
	))
	host.free()

func _test_knife_preserves_legacy_forward_reach(failures: Array[String]) -> void:
	_append(failures, Assertions.expect_float_near(
		_attack_isolated_target(Vector3(0.0, 0.0, -2.30)),
		50.0,
		0.0001,
		"Enlarged shooting cylinder does not extend Knife reach to 2.30 meters"
	))
	_append(failures, Assertions.expect_float_near(
		_attack_isolated_target(Vector3(0.0, 0.0, -1.90)),
		15.0,
		0.0001,
		"Knife still hits a target within its legacy forward reach"
	))

func _attack_isolated_target(target_position: Vector3) -> float:
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var target := TARGET_SCENE.instantiate() as ZombieTarget
	target.position = target_position
	tree.root.add_child(host)
	host.add_child(player)
	host.add_child(target)
	var equipment := player.get_node("EquipmentController") as EquipmentController
	equipment.equip_slot(2)
	var knife := equipment.get_current_weapon() as MeleeWeapon
	knife.set_physics_process(false)
	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.0)
	knife._physics_process(0.22)
	var remaining_health := target.health.current
	host.free()
	return remaining_health

func _on_melee_attack_started(_animation_name: StringName, _lock_duration: float) -> void:
	melee_attack_started_emissions += 1

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
