extends RefCounted
class_name MenuFlow

enum State {
	READY,
	STARTING,
	EXIT_CONFIRM,
}

var state: State = State.READY

func request_single() -> bool:
	return _request_start()

func request_local() -> bool:
	return _request_start()

func _request_start() -> bool:
	if state != State.READY:
		return false
	state = State.STARTING
	return true

func request_exit() -> bool:
	if state != State.READY:
		return false
	state = State.EXIT_CONFIRM
	return true

func cancel_exit() -> bool:
	if state != State.EXIT_CONFIRM:
		return false
	state = State.READY
	return true

func confirm_exit() -> bool:
	return state == State.EXIT_CONFIRM
