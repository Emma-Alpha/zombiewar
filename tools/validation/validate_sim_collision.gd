extends SceneTree

const SimCollisionScript = preload("res://scripts/sim/sim_collision.gd")
const FlowFieldGridScript = preload("res://scripts/sim/flow_field_grid.gd")
const DeterministicRngScript = preload("res://scripts/sim/deterministic_rng.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_check_pair_separation(failures)
	_check_matches_naive_reference(failures)
	_check_traversal_order_stability(failures)
	_check_degenerate_overlap(failures)
	_check_circle_push(failures)
	_check_blocker_pushout(failures)
	_finish(failures)

func _check_pair_separation(failures: Array[String]) -> void:
	var positions := PackedVector2Array([Vector2(0.0, 0.0), Vector2(0.4, 0.0)])
	var radii := PackedFloat32Array([0.42, 0.42])
	var displacement := SimCollisionScript.accumulate_separation(
		positions, radii, 2, SimCollisionScript.DEFAULT_HASH_CELL_SIZE, 1.0
	)
	_expect(
		is_equal_approx(displacement[0].x, -displacement[1].x),
		"an overlapping pair must separate symmetrically",
		failures
	)
	_expect(displacement[0].x < 0.0, "the lower index must be pushed away from the higher", failures)
	var separated := (positions[1] + displacement[1]) - (positions[0] + displacement[0])
	_expect(
		absf(separated.length() - 0.84) < 0.0001,
		"a fully applied separation must reach the summed radii",
		failures
	)
	var untouched := SimCollisionScript.accumulate_separation(
		PackedVector2Array([Vector2.ZERO, Vector2(3.0, 0.0)]),
		radii,
		2,
		SimCollisionScript.DEFAULT_HASH_CELL_SIZE,
		1.0
	)
	_expect(
		untouched[0] == Vector2.ZERO and untouched[1] == Vector2.ZERO,
		"non-overlapping circles must produce no displacement",
		failures
	)

func _check_matches_naive_reference(failures: Array[String]) -> void:
	var rng = DeterministicRngScript.new()
	rng.seed_streams(20260807)
	var count := 300
	var positions := PackedVector2Array()
	var radii := PackedFloat32Array()
	for _index in range(count):
		positions.append(Vector2(
			rng.next_range(DeterministicRngScript.Stream.ZOMBIE_SPAWN, -8.0, 8.0),
			rng.next_range(DeterministicRngScript.Stream.ZOMBIE_SPAWN, -6.0, 6.0)
		))
		radii.append(0.42)
	var hashed := SimCollisionScript.accumulate_separation(
		positions, radii, count, SimCollisionScript.DEFAULT_HASH_CELL_SIZE, 0.5
	)
	var naive := _naive_separation(positions, radii, count, 0.5)
	var mismatches := 0
	for index in range(count):
		if not hashed[index].is_equal_approx(naive[index]):
			mismatches += 1
	_expect(
		mismatches == 0,
		"spatial hash separation must equal the ascending-order naive reference (%d mismatches)" % mismatches,
		failures
	)

func _check_traversal_order_stability(failures: Array[String]) -> void:
	var rng = DeterministicRngScript.new()
	rng.seed_streams(7)
	var count := 200
	var positions := PackedVector2Array()
	var radii := PackedFloat32Array()
	for _index in range(count):
		positions.append(Vector2(
			rng.next_range(DeterministicRngScript.Stream.ZOMBIE_WANDER, -3.0, 3.0),
			rng.next_range(DeterministicRngScript.Stream.ZOMBIE_WANDER, -3.0, 3.0)
		))
		radii.append(0.42)
	var first := SimCollisionScript.accumulate_separation(
		positions, radii, count, SimCollisionScript.DEFAULT_HASH_CELL_SIZE, 0.5
	)
	for _repeat in range(8):
		var again := SimCollisionScript.accumulate_separation(
			positions, radii, count, SimCollisionScript.DEFAULT_HASH_CELL_SIZE, 0.5
		)
		_expect(again == first, "repeated resolution must be bit-identical", failures)
	var buckets := SimCollisionScript.build_spatial_hash(
		positions, count, SimCollisionScript.DEFAULT_HASH_CELL_SIZE
	)
	var ascending := true
	for key in buckets.keys():
		var bucket: PackedInt32Array = buckets[key]
		for slot in range(1, bucket.size()):
			if bucket[slot] <= bucket[slot - 1]:
				ascending = false
	_expect(ascending, "every hash bucket must hold ascending entity indices", failures)

func _check_degenerate_overlap(failures: Array[String]) -> void:
	var positions := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	var radii := PackedFloat32Array([0.42, 0.42, 0.42])
	var displacement := SimCollisionScript.accumulate_separation(
		positions, radii, 3, SimCollisionScript.DEFAULT_HASH_CELL_SIZE, 1.0
	)
	_expect(
		displacement[0].y == 0.0 and displacement[1].y == 0.0 and displacement[2].y == 0.0,
		"exactly coincident circles must resolve along a fixed axis",
		failures
	)
	_expect(
		displacement[0].x < displacement[2].x,
		"coincident circles must still fan out by ascending index",
		failures
	)

func _check_circle_push(failures: Array[String]) -> void:
	var push := SimCollisionScript.resolve_circle_push(
		Vector2(0.2, 0.0), 0.42, Vector2.ZERO, 0.45
	)
	_expect(push.x > 0.0 and push.y == 0.0, "the zombie must be pushed away from the player", failures)
	_expect(
		absf((Vector2(0.2, 0.0) + push).length() - 0.87) < 0.0001,
		"the push must exactly clear the summed radii",
		failures
	)
	_expect(
		SimCollisionScript.resolve_circle_push(
			Vector2(5.0, 0.0), 0.42, Vector2.ZERO, 0.45
		) == Vector2.ZERO,
		"a distant player must not push the zombie",
		failures
	)

func _check_blocker_pushout(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2(-4.5, -4.5), 1.0, 9, 9)
	grid.set_blocked(grid.world_to_cell(Vector2(0.0, 0.0)), true)
	var outside := SimCollisionScript.resolve_blocker(Vector2(2.5, 2.5), 0.42, grid)
	_expect(outside == Vector2.ZERO, "a circle clear of every blocker must not move", failures)
	var grazing := Vector2(0.8, 0.0)
	var correction := SimCollisionScript.resolve_blocker(grazing, 0.42, grid)
	_expect(correction.x > 0.0, "an overlapping circle must be pushed out of the blocked cell", failures)
	var resolved := grazing + correction
	_expect(
		resolved.x >= 0.5 + 0.42 - 0.0001,
		"the resolved circle must clear the blocked cell face",
		failures
	)
	var inside := SimCollisionScript.resolve_blocker(Vector2(0.1, 0.0), 0.42, grid)
	_expect(
		absf(Vector2(0.1, 0.0).x + inside.x) >= 0.5 + 0.42 - 0.0001 or
		absf(Vector2(0.1, 0.0).y + inside.y) >= 0.5 + 0.42 - 0.0001,
		"a circle centred inside a blocker must be ejected along the shallowest axis",
		failures
	)
	var repeated := SimCollisionScript.resolve_blocker(grazing, 0.42, grid)
	_expect(repeated == correction, "blocker resolution must be bit-identical across calls", failures)

func _naive_separation(
	positions: PackedVector2Array,
	radii: PackedFloat32Array,
	count: int,
	ratio: float
) -> PackedVector2Array:
	var displacement := PackedVector2Array()
	displacement.resize(count)
	displacement.fill(Vector2.ZERO)
	for index in range(count):
		for other_index in range(index + 1, count):
			var offset: Vector2 = positions[other_index] - positions[index]
			var combined: float = radii[index] + radii[other_index]
			var distance_squared := offset.length_squared()
			if distance_squared >= combined * combined:
				continue
			var push := Vector2.ZERO
			if distance_squared <= 0.000001:
				push = Vector2(combined * 0.5 * ratio, 0.0)
			else:
				var distance := sqrt(distance_squared)
				push = offset / distance * ((combined - distance) * 0.5 * ratio)
			displacement[index] -= push
			displacement[other_index] += push
	return displacement

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_sim_collision: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
