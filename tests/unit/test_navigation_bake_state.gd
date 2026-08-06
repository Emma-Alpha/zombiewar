extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const NavigationBakeState = preload("res://scripts/navigation/navigation_bake_state.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var state := NavigationBakeState.new()

	_append(failures, Assertions.expect_true(state.queue_bake(), "First request schedules work"))
	_append(failures, Assertions.expect_true(not state.queue_bake(), "Queued requests merge"))
	_append(failures, Assertions.expect_equal(
		state.status,
		NavigationBakeState.Status.QUEUED,
		"Merged request stays queued"
	))

	var first_generation := state.begin_bake()
	_append(failures, Assertions.expect_true(first_generation > 0, "Queued bake starts"))
	_append(failures, Assertions.expect_true(
		state.is_active_generation(first_generation),
		"Started generation becomes active"
	))
	_append(failures, Assertions.expect_true(
		not state.queue_bake(),
		"Request during bake does not start concurrent work"
	))
	_append(failures, Assertions.expect_true(
		state.complete_success(first_generation),
		"Active generation can complete"
	))
	_append(failures, Assertions.expect_equal(
		state.status,
		NavigationBakeState.Status.QUEUED,
		"Dirty-during-bake schedules one follow-up"
	))
	_append(failures, Assertions.expect_true(state.has_usable_mesh, "Success records usable mesh"))
	_append(failures, Assertions.expect_true(state.is_stale, "Old mesh is stale before follow-up"))

	var second_generation := state.begin_bake()
	_append(failures, Assertions.expect_true(
		state.complete_failure(second_generation, "synthetic failure"),
		"Active failure is accepted"
	))
	_append(failures, Assertions.expect_equal(
		state.status,
		NavigationBakeState.Status.READY,
		"Rebake failure keeps old mesh ready"
	))
	_append(failures, Assertions.expect_true(state.is_stale, "Failed rebake leaves stale mesh"))
	_append(failures, Assertions.expect_equal(
		state.last_error,
		"synthetic failure",
		"Failure reason is retained"
	))

	var stale_generation := second_generation
	state.queue_bake()
	var current_generation := state.begin_bake()
	_append(failures, Assertions.expect_true(
		not state.complete_success(stale_generation),
		"Outdated callback cannot replace current work"
	))
	state.invalidate()
	_append(failures, Assertions.expect_true(
		not state.complete_success(current_generation),
		"Invalidation rejects in-flight callbacks"
	))

	var initial_failure := NavigationBakeState.new()
	initial_failure.queue_bake()
	var initial_generation := initial_failure.begin_bake()
	initial_failure.complete_failure(initial_generation, "no geometry")
	_append(failures, Assertions.expect_equal(
		initial_failure.status,
		NavigationBakeState.Status.FAILED,
		"Initial failure has no ready fallback"
	))
	_append(failures, Assertions.expect_true(
		not initial_failure.has_usable_mesh,
		"Initial failure has no usable mesh"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
