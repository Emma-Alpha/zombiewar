extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PROP_CONTRACTS: Array[Dictionary] = [
	{
		"path": "res://scenes/props/TrafficBarrier.tscn",
		"root_name": &"TrafficBarrier",
		"shape_size": Vector3(1.56, 1.12, 0.88),
		"shape_position": Vector3(0.0, 0.56, 0.0),
	},
	{
		"path": "res://scenes/props/PlasticBarrier.tscn",
		"root_name": &"PlasticBarrier",
		"shape_size": Vector3(1.04, 0.60, 0.34),
		"shape_position": Vector3(0.0, 0.30, 0.0),
	},
	{
		"path": "res://scenes/props/SupplyChest.tscn",
		"root_name": &"SupplyChest",
		"shape_size": Vector3(0.64, 0.41, 0.48),
		"shape_position": Vector3(0.0, 0.205, 0.0),
	},
]

func run() -> Array[String]:
	var failures: Array[String] = []
	for contract in PROP_CONTRACTS:
		_test_prop_contract(failures, contract)
	return failures

func _test_prop_contract(
	failures: Array[String],
	contract: Dictionary
) -> void:
	var packed := load(String(contract["path"])) as PackedScene
	_append(failures, Assertions.expect_true(
		packed != null,
		"Checkpoint prop scene loads: %s" % contract["path"]
	))
	if packed == null:
		return
	var body := packed.instantiate() as StaticBody3D
	_append(failures, Assertions.expect_true(
		body != null and body.name == contract["root_name"],
		"Checkpoint prop owns the planned StaticBody3D root: %s" % contract["path"]
	))
	if body == null:
		return
	var visual := body.get_node_or_null("Visual") as Node3D
	var collision := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	var shape: BoxShape3D
	if collision != null:
		shape = collision.shape as BoxShape3D
	_append(failures, Assertions.expect_true(
		body.collision_layer == 1 and body.collision_mask == 0 and
		body.is_in_group(&"navigation_source") and
		body.is_in_group(&"place_item_obstacle"),
		"Checkpoint prop exposes world collision and navigation/place groups: %s" % contract["path"]
	))
	_append(failures, Assertions.expect_true(
		visual != null and not visual.is_in_group(&"navigation_source"),
		"Checkpoint prop keeps its imported visual outside navigation groups: %s" % contract["path"]
	))
	_append(failures, Assertions.expect_true(
		shape != null,
		"Checkpoint prop uses a BoxShape3D: %s" % contract["path"]
	))
	if shape != null and collision != null:
		_append(failures, Assertions.expect_vector3_near(
			shape.size,
			contract["shape_size"],
			0.001,
			"Checkpoint prop collision size matches the low-poly model"
		))
		_append(failures, Assertions.expect_vector3_near(
			collision.position,
			contract["shape_position"],
			0.001,
			"Checkpoint prop collision rests on the ground"
		))
	body.free()

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
