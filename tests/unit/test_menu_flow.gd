extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const MenuFlow = preload("res://scripts/menu/menu_flow.gd")

func run() -> Array[String]:
	var failures: Array[String] = []

	var start_flow := MenuFlow.new()
	_append(failures, Assertions.expect_equal(
		start_flow.state,
		MenuFlow.State.READY,
		"Menu starts ready"
	))
	_append(failures, Assertions.expect_true(
		start_flow.request_start(),
		"Ready menu accepts start"
	))
	_append(failures, Assertions.expect_equal(
		start_flow.state,
		MenuFlow.State.STARTING,
		"Start request enters starting state"
	))
	_append(failures, Assertions.expect_true(
		not start_flow.request_start(),
		"Starting menu rejects duplicate start"
	))
	_append(failures, Assertions.expect_true(
		not start_flow.request_exit(),
		"Starting menu rejects exit"
	))

	var exit_flow := MenuFlow.new()
	_append(failures, Assertions.expect_true(
		exit_flow.request_exit(),
		"Ready menu opens exit confirmation"
	))
	_append(failures, Assertions.expect_equal(
		exit_flow.state,
		MenuFlow.State.EXIT_CONFIRM,
		"Exit request enters confirmation state"
	))
	_append(failures, Assertions.expect_true(
		exit_flow.confirm_exit(),
		"Confirmation state allows application exit"
	))
	_append(failures, Assertions.expect_true(
		exit_flow.cancel_exit(),
		"Confirmation can be cancelled"
	))
	_append(failures, Assertions.expect_equal(
		exit_flow.state,
		MenuFlow.State.READY,
		"Cancel returns menu to ready state"
	))
	_append(failures, Assertions.expect_true(
		not exit_flow.confirm_exit(),
		"Ready state cannot confirm application exit"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
