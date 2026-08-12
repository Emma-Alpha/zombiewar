extends RefCounted
class_name SimWaveDirector

## 纯数据的确定性波次状态机。调用方只传入已编译的 Dictionary，状态机不持有
## Node、Resource、Timer，也不读取墙钟时间。
enum EndMode { COMPLETE, LOOP }
enum State { IDLE, SPAWNING, WAITING_CLEAR, INTERMISSION, COMPLETE }

var state := State.IDLE
var wave_index := 0
var entry_index := 0
var remaining_in_entry := 0
var spawn_point_cursor := 0
var next_spawn_tick := 0
var intermission_end_tick := 0
var completion_emitted := false
var wave_number := 0
var wave_start_pending := false

var waves: Array[Dictionary] = []
var spawn_points: Array[Dictionary] = []
var end_mode := EndMode.COMPLETE
var inter_wave_delay_ticks := 0
var maximum_active_zombies := 0

func configure(
	value_waves: Array[Dictionary],
	value_spawn_points: Array[Dictionary],
	value_end_mode: int,
	value_inter_wave_delay_ticks: int,
	value_maximum_active_zombies: int
) -> void:
	waves = []
	for value_wave in value_waves:
		var entries: Array[Dictionary] = []
		for value_entry in value_wave.get("entries", []):
			entries.append({
				"profile_index": int(value_entry.get("profile_index", -1)),
				"count": maxi(int(value_entry.get("count", 0)), 0),
			})
		waves.append({
			"spawn_interval_ticks": maxi(
				int(value_wave.get("spawn_interval_ticks", 0)), 0
			),
			"entries": entries,
		})
	spawn_points = []
	for value_spawn_point in value_spawn_points:
		spawn_points.append({
			"spawn_id": StringName(value_spawn_point.get("spawn_id", StringName())),
			"position": Vector2(value_spawn_point.get("position", Vector2.ZERO)),
			"radius": maxf(float(value_spawn_point.get("radius", 0.0)), 0.0),
			"spacing": maxf(float(value_spawn_point.get("spacing", 0.0)), 0.0),
		})
	spawn_points.sort_custom(_spawn_point_less)
	end_mode = (
		EndMode.LOOP
		if value_end_mode == EndMode.LOOP
		else EndMode.COMPLETE
	)
	inter_wave_delay_ticks = maxi(value_inter_wave_delay_ticks, 0)
	maximum_active_zombies = maxi(value_maximum_active_zombies, 0)
	_reset_state()

func start(current_tick: int) -> void:
	_reset_state()
	if waves.is_empty() or spawn_points.is_empty() or maximum_active_zombies <= 0:
		return
	wave_index = 0
	_begin_wave(current_tick + 1)

func request_advance(current_tick: int) -> void:
	if state != State.INTERMISSION:
		return
	intermission_end_tick = mini(intermission_end_tick, current_tick)

func can_advance() -> bool:
	return state == State.INTERMISSION

func step_tick(
	current_tick: int,
	active_count: int,
	pending_count: int
) -> Array[Dictionary]:
	var commands_and_events: Array[Dictionary] = []
	if state == State.IDLE or state == State.COMPLETE:
		return commands_and_events
	if state == State.WAITING_CLEAR:
		if maxi(active_count, 0) + maxi(pending_count, 0) > 0:
			return commands_and_events
		_finish_wave(current_tick, commands_and_events)
	if state == State.INTERMISSION:
		if current_tick < intermission_end_tick:
			return commands_and_events
		_begin_wave(current_tick)
	if wave_start_pending:
		wave_start_pending = false
		commands_and_events.append({
			"kind": &"wave_started",
			"wave_number": wave_number,
		})
	if state == State.SPAWNING:
		_append_spawn_commands(
			current_tick,
			maxi(active_count, 0),
			maxi(pending_count, 0),
			commands_and_events
		)
	return commands_and_events

func get_state_words() -> PackedInt32Array:
	return PackedInt32Array([
		state,
		wave_index,
		entry_index,
		remaining_in_entry,
		spawn_point_cursor,
		next_spawn_tick,
		intermission_end_tick,
		1 if completion_emitted else 0,
		wave_number,
		1 if wave_start_pending else 0,
	])

func _reset_state() -> void:
	state = State.IDLE
	wave_index = 0
	entry_index = 0
	remaining_in_entry = 0
	spawn_point_cursor = 0
	next_spawn_tick = 0
	intermission_end_tick = 0
	completion_emitted = false
	wave_number = 0
	wave_start_pending = false

func _begin_wave(first_spawn_tick: int) -> void:
	state = State.SPAWNING
	wave_number += 1
	wave_start_pending = true
	entry_index = 0
	remaining_in_entry = 0
	next_spawn_tick = first_spawn_tick
	_load_next_nonempty_entry()

func _load_next_nonempty_entry() -> void:
	var entries: Array = waves[wave_index]["entries"]
	while entry_index < entries.size():
		remaining_in_entry = maxi(int(entries[entry_index].get("count", 0)), 0)
		if remaining_in_entry > 0:
			return
		entry_index += 1
	remaining_in_entry = 0
	state = State.WAITING_CLEAR

func _finish_wave(current_tick: int, output: Array[Dictionary]) -> void:
	var is_last_wave := wave_index >= waves.size() - 1
	if is_last_wave and end_mode == EndMode.COMPLETE:
		state = State.COMPLETE
		if not completion_emitted:
			completion_emitted = true
			output.append({"kind": &"map_completed"})
		return
	wave_index = 0 if is_last_wave else wave_index + 1
	state = State.INTERMISSION
	entry_index = 0
	remaining_in_entry = 0
	intermission_end_tick = current_tick + inter_wave_delay_ticks
	if inter_wave_delay_ticks == 0:
		_begin_wave(current_tick)

func _append_spawn_commands(
	current_tick: int,
	active_count: int,
	pending_count: int,
	output: Array[Dictionary]
) -> void:
	if current_tick < next_spawn_tick:
		return
	var active_and_pending := active_count + pending_count
	var spawn_interval_ticks := int(waves[wave_index]["spawn_interval_ticks"])
	while (
		state == State.SPAWNING and
		current_tick >= next_spawn_tick and
		active_and_pending < maximum_active_zombies
	):
		var entries: Array = waves[wave_index]["entries"]
		var entry: Dictionary = entries[entry_index]
		var spawn_point: Dictionary = spawn_points[spawn_point_cursor]
		output.append({
			"kind": &"spawn_zombie",
			"profile_index": int(entry["profile_index"]),
			"center": spawn_point["position"],
			"radius": spawn_point["radius"],
			"minimum_spacing": spawn_point["spacing"],
		})
		active_and_pending += 1
		spawn_point_cursor = (spawn_point_cursor + 1) % spawn_points.size()
		remaining_in_entry -= 1
		if remaining_in_entry <= 0:
			entry_index += 1
			_load_next_nonempty_entry()
		if spawn_interval_ticks > 0:
			next_spawn_tick = current_tick + spawn_interval_ticks
			return

func _spawn_point_less(left: Dictionary, right: Dictionary) -> bool:
	return String(left["spawn_id"]) < String(right["spawn_id"])
