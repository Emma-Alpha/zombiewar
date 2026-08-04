extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const MANAGER_SCRIPT := preload("res://scripts/fx/ground_blood_manager.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var manager := MANAGER_SCRIPT.new() as Node3D
	manager.set("max_splats", 3)

	var first := manager.call(
		"place_splat",
		Vector3(0, 0, 0),
		Vector3.UP,
		0.4,
		0.0,
		Color(0.45, 0.01, 0.02, 0.92)
	) as Node3D
	var second := manager.call(
		"place_splat",
		Vector3(1, 0, 0),
		Vector3.UP,
		0.5,
		0.4,
		Color(0.48, 0.01, 0.02, 0.9)
	) as Node3D
	var third := manager.call(
		"place_splat",
		Vector3(2, 0, 0),
		Vector3.UP,
		0.6,
		0.8,
		Color(0.42, 0.01, 0.02, 0.94)
	) as Node3D
	var reused := manager.call(
		"place_splat",
		Vector3(9, 0, 0),
		Vector3.UP,
		1.1,
		1.2,
		Color(0.5, 0.01, 0.02, 0.95)
	) as Node3D

	_append(failures, Assertions.expect_equal(
		manager.get_child_count(),
		3,
		"Ground blood never grows beyond the configured cap"
	))
	_append(failures, Assertions.expect_equal(
		reused.get_instance_id(),
		first.get_instance_id(),
		"The fourth splat reuses the oldest instance"
	))
	_append(failures, Assertions.expect_true(
		second.get_instance_id() != reused.get_instance_id() and
		third.get_instance_id() != reused.get_instance_id(),
		"Newer splats remain untouched during FIFO reuse"
	))
	_append(failures, Assertions.expect_true(
		not reused.is_processing(),
		"Persistent ground blood does not run a lifetime process"
	))
	_append(failures, Assertions.expect_vector3_near(
		reused.basis.z.normalized(),
		Vector3.UP,
		0.0001,
		"Ground blood plane aligns its normal to the hit surface"
	))

	manager.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
