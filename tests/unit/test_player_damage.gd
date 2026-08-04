extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")

var damage_emissions := 0
var death_emissions := 0

func run() -> Array[String]:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(player)
	var aim_indicator := player.get_node_or_null("Weapon/AimIndicator") as Node3D

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
	_append(failures, Assertions.expect_equal(
		damage_emissions,
		1,
		"A successful hit emits one damage event"
	))
	player.call("apply_damage", 1000.0, Vector3.RIGHT)
	_append(failures, Assertions.expect_true(
		not bool(player.call("is_alive")),
		"Lethal damage defeats player"
	))
	_append(failures, Assertions.expect_true(
		aim_indicator != null and not aim_indicator.visible,
		"Player death hides the persistent aim guide"
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
