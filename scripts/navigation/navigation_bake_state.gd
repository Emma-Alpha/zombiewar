extends RefCounted
class_name NavigationBakeState

## RETIRED (S0 确定性模拟地基, 2026-08-07)：随 NavigationChunk3D 一并退役。
## 保留但不得用于新功能。

enum Status {
	UNBAKED,
	QUEUED,
	BAKING,
	READY,
	FAILED,
}

var status := Status.UNBAKED
var requested_generation := 0
var active_generation := 0
var has_usable_mesh := false
var is_stale := false
var pending_after_active := false
var last_error := ""

func queue_bake() -> bool:
	requested_generation += 1
	if has_usable_mesh:
		is_stale = true
	match status:
		Status.QUEUED:
			return false
		Status.BAKING:
			pending_after_active = true
			return false
		_:
			status = Status.QUEUED
			return true

func begin_bake() -> int:
	if status != Status.QUEUED:
		return 0
	status = Status.BAKING
	active_generation = requested_generation
	pending_after_active = false
	return active_generation

func is_active_generation(generation: int) -> bool:
	return status == Status.BAKING and generation == active_generation

func complete_success(generation: int) -> bool:
	if not is_active_generation(generation):
		return false
	has_usable_mesh = true
	last_error = ""
	if pending_after_active or requested_generation > generation:
		status = Status.QUEUED
		is_stale = true
		pending_after_active = false
	else:
		status = Status.READY
		is_stale = false
	return true

func complete_failure(generation: int, message: String) -> bool:
	if not is_active_generation(generation):
		return false
	last_error = message
	if pending_after_active or requested_generation > generation:
		status = Status.QUEUED
		pending_after_active = false
		is_stale = has_usable_mesh
	else:
		status = Status.READY if has_usable_mesh else Status.FAILED
		is_stale = has_usable_mesh
	return true

func invalidate() -> void:
	requested_generation += 1
	active_generation = 0
	pending_after_active = false
	status = Status.UNBAKED
	has_usable_mesh = false
	is_stale = false
	last_error = ""

func snapshot() -> Dictionary:
	return {
		"status": status,
		"requested_generation": requested_generation,
		"active_generation": active_generation,
		"has_usable_mesh": has_usable_mesh,
		"is_stale": is_stale,
		"last_error": last_error,
	}
