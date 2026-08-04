extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ZOMBIE_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")
const BLOOD_SCENE_PATH := "res://scenes/fx/BloodImpact.tscn"

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load(BLOOD_SCENE_PATH) as PackedScene
	_append(failures, Assertions.expect_true(
		packed != null,
		"Blood impact scene loads"
	))
	if packed == null:
		return failures

	var effect := packed.instantiate()
	var splat := effect.get_node_or_null("Splat") as Sprite3D
	var droplets := effect.get_node_or_null("Droplets") as GPUParticles3D
	_append(failures, Assertions.expect_true(
		effect.has_method("setup"),
		"Blood impact exposes a setup entry point"
	))
	_append(failures, Assertions.expect_true(
		splat != null and splat.texture != null,
		"Blood impact uses an imported splat texture"
	))
	_append(failures, Assertions.expect_true(
		droplets != null and droplets.one_shot and droplets.amount >= 12,
		"Blood impact has a one-shot droplet burst"
	))
	effect.free()

	var host := Node3D.new()
	var target := ZOMBIE_SCENE.instantiate()
	host.add_child(target)
	var initial_children := host.get_child_count()
	target.call(
		"apply_hit",
		10.0,
		Vector3(0.0, 1.1, 0.0),
		Vector3.FORWARD,
		&"torso",
		1.0,
		1.0,
		0.06
	)
	_append(failures, Assertions.expect_equal(
		host.get_child_count(),
		initial_children + 1,
		"Successful zombie hit spawns one blood impact"
	))
	if host.get_child_count() == initial_children + 1:
		var spawned := host.get_child(initial_children)
		_append(failures, Assertions.expect_equal(
			spawned.scene_file_path,
			BLOOD_SCENE_PATH,
			"Zombie spawns the shared BloodImpact scene"
		))
	host.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
