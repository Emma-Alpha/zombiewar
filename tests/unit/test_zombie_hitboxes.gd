extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ZOMBIE_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")
const HitResult = preload("res://scripts/combat/hit_result.gd")

const REQUIRED_HITBOXES: Array[StringName] = [
	&"HeadHitbox",
	&"TorsoHitbox",
	&"LeftSideHitbox",
	&"RightSideHitbox",
	&"LegsHitbox",
]

func run() -> Array[String]:
	var failures: Array[String] = []
	var head_target := ZOMBIE_SCENE.instantiate()
	var torso_target := ZOMBIE_SCENE.instantiate()

	_append(failures, Assertions.expect_true(
		head_target is CharacterBody3D,
		"Zombie target uses collision-aware CharacterBody3D knockback"
	))
	var hitbox_root := head_target.get_node_or_null("Hitboxes")
	_append(failures, Assertions.expect_true(
		hitbox_root != null,
		"Zombie target exposes a dedicated hitbox root"
	))
	if hitbox_root != null:
		_append(failures, Assertions.expect_true(
			hitbox_root.get_child_count() >= REQUIRED_HITBOXES.size(),
			"Zombie exposes at least five forgiving body-region hitboxes"
		))
		for hitbox_name in REQUIRED_HITBOXES:
			var hitbox := hitbox_root.get_node_or_null(NodePath(hitbox_name))
			_append(failures, Assertions.expect_true(
				hitbox is Area3D,
				"%s is an Area3D hitbox" % hitbox_name
			))
			if hitbox is Area3D:
				_append(failures, Assertions.expect_equal(
					hitbox.collision_layer,
					4,
					"%s is visible to the weapon ray" % hitbox_name
				))
				_append(failures, Assertions.expect_true(
					hitbox.has_method("apply_hit"),
					"%s forwards typed hit data" % hitbox_name
				))
				var shape := hitbox.get_node_or_null("CollisionShape3D") as CollisionShape3D
				_append(failures, Assertions.expect_true(
					shape != null and shape.shape != null,
					"%s has a usable collision shape" % hitbox_name
				))

	var head_hitbox := head_target.get_node_or_null("Hitboxes/HeadHitbox")
	var torso_hitbox := torso_target.get_node_or_null("Hitboxes/TorsoHitbox")
	if head_hitbox != null and torso_hitbox != null:
		var head_result := head_hitbox.call(
			"apply_hit",
			10.0,
			head_target.position + Vector3.UP * 1.7,
			Vector3.RIGHT
		) as HitResult
		var torso_result := torso_hitbox.call(
			"apply_hit",
			10.0,
			torso_target.position + Vector3.UP,
			Vector3.RIGHT
		) as HitResult
		_append(failures, Assertions.expect_true(
			head_result != null and head_result.critical,
			"Head hit returns a critical HitResult"
		))
		_append(failures, Assertions.expect_true(
			torso_result != null and not torso_result.critical,
			"Torso hit returns a non-critical HitResult"
		))
		var head_health = head_target.get("health")
		var torso_health = torso_target.get("health")
		_append(failures, Assertions.expect_true(
			head_health.current < torso_health.current,
			"Head hit applies more damage than torso hit"
		))
		var head_velocity: Vector3 = head_target.get("velocity")
		var torso_velocity: Vector3 = torso_target.get("velocity")
		_append(failures, Assertions.expect_true(
			head_velocity.x > torso_velocity.x,
			"Head hit applies more horizontal knockback than torso hit"
		))
		_append(failures, Assertions.expect_true(
			head_velocity.y > torso_velocity.y,
			"Head hit applies more vertical lift than torso hit"
		))

	head_target.free()
	torso_target.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
