extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ZOMBIE_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")
const HitResult = preload("res://scripts/combat/hit_result.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var target := ZOMBIE_SCENE.instantiate() as ZombieTarget
	var hitbox_root := target.get_node_or_null("Hitboxes")
	var body_hitbox := target.get_node_or_null("Hitboxes/BodyHitbox") as Area3D
	var collision_shape := target.get_node_or_null(
		"Hitboxes/BodyHitbox/CollisionShape3D"
	) as CollisionShape3D
	var cylinder := collision_shape.shape as CylinderShape3D if collision_shape != null else null

	_append(failures, Assertions.expect_true(
		target is CharacterBody3D,
		"Zombie target uses collision-aware CharacterBody3D knockback"
	))
	_append(failures, Assertions.expect_equal(
		hitbox_root.get_child_count() if hitbox_root != null else 0,
		1,
		"Zombie exposes one forgiving shooting hitbox"
	))
	_append(failures, Assertions.expect_true(
		body_hitbox != null and body_hitbox.collision_layer == 4,
		"Body hitbox is visible to weapon rays"
	))
	_append(failures, Assertions.expect_true(
		cylinder != null,
		"Body hitbox uses a direction-independent cylinder"
	))
	if cylinder != null:
		_append(failures, Assertions.expect_float_near(
			cylinder.radius, 1.1, 0.0001, "Body hitbox radius"
		))
		_append(failures, Assertions.expect_float_near(
			cylinder.height, 2.2, 0.0001, "Body hitbox height"
		))

	for hit_height in [0.35, 1.1, 1.85]:
		var height_target := ZOMBIE_SCENE.instantiate() as ZombieTarget
		var height_hitbox := height_target.get_node_or_null("Hitboxes/BodyHitbox") as Area3D
		if height_hitbox != null:
			var result := height_hitbox.call(
				"apply_hit",
				10.0,
				Vector3(0.0, hit_height, 0.0),
				Vector3.RIGHT
			) as HitResult
			_append(failures, Assertions.expect_true(
				result.did_hit and not result.critical and result.hit_zone == &"body",
				"Every visible body height resolves as a normal body hit"
			))
			_append(failures, Assertions.expect_float_near(
				result.damage_applied, 10.0, 0.0001,
				"Every visible body height applies base damage"
			))
		height_target.free()

	target.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
