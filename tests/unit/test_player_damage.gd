extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const EquipmentController = preload("res://scripts/player/equipment_controller.gd")

var damage_emissions := 0
var death_emissions := 0

func run() -> Array[String]:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(player)
	var health_bar := player.get_node_or_null("HealthBar3D") as HealthBar3D
	var equipment := player.get_node_or_null("EquipmentController") as EquipmentController
	var weapon := equipment.get_current_weapon() if equipment != null else null
	if weapon != null:
		weapon.set_attack_input(true, true, Vector3.FORWARD)

	_append(failures, Assertions.expect_true(
		player.has_method("is_alive") and player.has_method("apply_damage"),
		"Player exposes a damageable life-cycle API"
	))
	if not player.has_method("is_alive") or not player.has_method("apply_damage"):
		player.free()
		return failures

	damage_emissions = 0
	death_emissions = 0
	player.damaged.connect(_on_damaged)
	player.died.connect(_on_died)
	_append(failures, Assertions.expect_true(
		bool(player.call("is_alive")),
		"Player starts alive"
	))
	_append(failures, Assertions.expect_true(
		health_bar != null and is_equal_approx(health_bar.get_target_ratio(), 1.0),
		"Player starts with a full overhead health bar"
	))
	_append(failures, Assertions.expect_float_near(
		float(player.call("apply_damage", 10.0, Vector3.RIGHT)),
		10.0,
		0.0001,
		"Player accepts zombie damage"
	))
	var health: Variant = player.get("health")
	_append(failures, Assertions.expect_true(
		health != null,
		"Player owns the shared Health model"
	))
	if health != null:
		_append(failures, Assertions.expect_float_near(
			health.current,
			90.0,
			0.0001,
			"Player health decreases after a hit"
		))
	_append(failures, Assertions.expect_float_near(
		health_bar.get_target_ratio() if health_bar != null else -1.0,
		0.9,
		0.0001,
		"Player overhead health bar follows damage"
	))
	_append(failures, Assertions.expect_equal(
		damage_emissions,
		1,
		"A successful hit emits one damage event"
	))
	_append(failures, Assertions.expect_true(
		weapon != null and not weapon.trigger_pressed and not weapon.trigger_just_pressed,
		"Taking damage cancels the current weapon attack"
	))
	var weapon_collision := player.get_node("WeaponCollision") as CollisionShape3D
	player.set("attack_animation_remaining", 0.5)
	player.call("apply_damage", 1000.0, Vector3.RIGHT)
	_append(failures, Assertions.expect_true(
		not bool(player.call("is_alive")),
		"Lethal damage defeats player"
	))
	_append(failures, Assertions.expect_float_near(
		health_bar.get_target_ratio() if health_bar != null else -1.0,
		0.0,
		0.0001,
		"Player overhead health bar empties on death"
	))
	_append(failures, Assertions.expect_true(
		weapon_collision.disabled,
		"Player death disables firearm wall collision"
	))
	_append(failures, Assertions.expect_true(
		weapon != null and not weapon.trigger_pressed and not weapon.trigger_just_pressed,
		"Player death keeps the current weapon attack cancelled"
	))
	_append(failures, Assertions.expect_equal(
		death_emissions,
		1,
		"Player death emits once"
	))
	_append(failures, Assertions.expect_float_near(
		float(player.get("hit_reaction_remaining")),
		0.0,
		0.0001,
		"Death clears the temporary hit-reaction lock"
	))
	_append(failures, Assertions.expect_float_near(
		float(player.get("attack_animation_remaining")),
		0.0,
		0.0001,
		"Death clears the weapon attack animation lock"
	))
	_append(failures, Assertions.expect_float_near(
		float(player.call("apply_damage", 10.0, Vector3.RIGHT)),
		0.0,
		0.0001,
		"Defeated player ignores further damage"
	))
	_append(failures, Assertions.expect_equal(
		damage_emissions,
		2,
		"Ignored post-death damage emits no extra damage event"
	))
	_append(failures, Assertions.expect_equal(
		death_emissions,
		1,
		"Ignored post-death damage emits no extra death event"
	))
	player.free()
	return failures

func _on_damaged(_amount: float) -> void:
	damage_emissions += 1

func _on_died() -> void:
	death_emissions += 1

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
