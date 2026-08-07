extends RefCounted
class_name SimWorld

## 全部模拟状态的唯一持有者。结构化数组（SoA），不持有任何 Node。
const SimClockScript = preload("res://scripts/sim/sim_clock.gd")
const DeterministicRngScript = preload("res://scripts/sim/deterministic_rng.gd")
const FlowFieldGridScript = preload("res://scripts/sim/flow_field_grid.gd")
const FlowFieldScript = preload("res://scripts/sim/flow_field.gd")
const SimCollisionScript = preload("res://scripts/sim/sim_collision.gd")
const ZombieBehaviorMathScript = preload("res://scripts/combat/zombie_behavior_math.gd")
const MeleeAttackCycleScript = preload("res://scripts/combat/melee_attack_cycle.gd")
const HitResponseMathScript = preload("res://scripts/combat/hit_response_math.gd")
const WeaponSpreadStateScript = preload(
	"res://scripts/combat/weapons/weapon_spread_state.gd"
)
const SimCombatScript = preload("res://scripts/sim/sim_combat.gd")
const SimHitGeometryScript = preload("res://scripts/sim/sim_hit_geometry.gd")

const MAX_PLAYER_SLOTS := 4
const NO_TARGET_SLOT := 255
const STATE_DEAD := 3
const HEALTH_SCALE := 100
const POSITION_QUANTIZATION := 1000.0

## 与 Godot 的 physics/3d/default_gravity 引擎缺省值一致；project.godot 未覆盖该项
## （基线的 zombie_target.gd 是用 ProjectSettings.get_setting(..., 9.8) 读到同一个缺省值的），
## 模拟层不读 ProjectSettings，因此在此固化。
const SIM_GRAVITY := 9.8

const ZOMBIE_RADIUS := 0.42
const PLAYER_RADIUS := 0.45
const ZOMBIE_SEPARATION_RATIO := 0.5

## 感知半径不是常量：基线 spawn_wave() 会用 DemoArena.wave_perception_range（默认 60.0）
## 覆盖 ZombieTarget.tscn 的导出默认值 7.0，波次僵尸实际用的是 60.0。
## 若在此把 7.0 固化成常量，僵尸只会在 7 m 内才注意到玩家，
## 而生成角在 (±19, ±14)、场地 48 × 38，新生成的僵尸会原地游荡不再汇聚。
## 因此由装配方（DemoArena._setup_simulation()）通过 set_perception_range() 注入。
const DEFAULT_PERCEPTION_RANGE := 60.0
var perception_range := DEFAULT_PERCEPTION_RANGE

# 下列数值逐字取自 scenes/targets/ZombieTarget.tscn 与 zombie_target.gd 的导出默认值。
const ZOMBIE_PERCEPTION_EXIT_MARGIN := 1.0
const ZOMBIE_TARGET_SWITCH_MARGIN := 0.5
const ZOMBIE_ATTACK_RANGE := 1.45
const ZOMBIE_ATTACK_DAMAGE := 10.0
const ZOMBIE_WANDER_SPEED := 0.55
const ZOMBIE_WANDER_RADIUS := 3.5
const ZOMBIE_WANDER_ARRIVE_RANGE := 0.25
const ZOMBIE_WANDER_SLOW_RADIUS := 0.8
const ZOMBIE_PERCEPTION_SLOW_RADIUS := 1.5
const ZOMBIE_MOVE_ACCELERATION := 5.0
const ZOMBIE_GROUND_DRAG := 11.0
const ZOMBIE_KNOCKBACK_IMPULSE := 6.0
const ZOMBIE_KNOCKBACK_VERTICAL_BIAS := 0.05
const DEFAULT_PERCEPTION_MOVE_SPEED := 1.30

# 秒 -> tick（TICK_SECONDS = 0.05）
const ZOMBIE_ATTACK_COOLDOWN_TICKS := 28   # 1.40 s
const ZOMBIE_ATTACK_WINDUP_TICKS := 10     # 0.50 s
const ZOMBIE_WANDER_PAUSE_MIN_TICKS := 8   # 0.40 s
const ZOMBIE_WANDER_PAUSE_MAX_TICKS := 24  # 1.20 s

# 下列常量新增，基线无对应导出项：被击中后的短暂僵直，用于取消攻击蓄力。
# 基线的 ZombieTarget 只有 _play_hit_reaction() 的纯视觉反馈，没有僵直状态。
const ZOMBIE_HIT_STUN_TICKS := 4           # 0.20 s

# ---- spec 指定的 SoA 字段 ----
var zombie_id := PackedInt32Array()
var zombie_position := PackedVector2Array()
var zombie_height := PackedFloat32Array()
var zombie_facing := PackedFloat32Array()
var zombie_health := PackedInt32Array()
var zombie_state := PackedByteArray()
var zombie_target_slot := PackedByteArray()

# ---- 推进与插值所需的内部字段 ----
var zombie_max_health := PackedInt32Array()
var zombie_previous_position := PackedVector2Array()
var zombie_previous_height := PackedFloat32Array()
var zombie_previous_facing := PackedFloat32Array()
var zombie_velocity := PackedVector2Array()
var zombie_vertical_velocity := PackedFloat32Array()
var zombie_radius := PackedFloat32Array()
var zombie_home := PackedVector2Array()
var zombie_wander_target := PackedVector2Array()
var zombie_wander_pause_ticks := PackedInt32Array()
var zombie_hit_stun_ticks := PackedInt32Array()
var zombie_move_speed := PackedFloat32Array()
var zombie_attack_state := PackedInt32Array()

# ---- 玩家量化快照（只读输入） ----
var player_position_quantized := PackedInt32Array()
var player_alive := PackedByteArray()
var player_present := PackedByteArray()

# ---- 子系统 ----
var rng: DeterministicRng
var grid: FlowFieldGrid
var flow_field: FlowField

var tick_index := 0
var next_entity_id := 1
var default_move_speed := DEFAULT_PERCEPTION_MOVE_SPEED
var pending_spawn_waves: Array = []
## 已排队但尚未在 tick 中兑现的生成名额。表现层用它把「排队中」计入活跃数，
## 避免同一物理帧内两次排队各自看到同一个 remaining_capacity 而突破上限。
var pending_spawn_capacity := 0

# ---- 本 tick 产生的表现层事件（每 tick 开头清空） ----
var tick_hit_events: Array = []
var tick_death_events := PackedInt32Array()
var tick_spawn_events := PackedInt32Array()
var tick_player_damage_events: Array = []
var tick_shot_events: Array = []

# ---- 武器档案与逐槽位散布状态 ----
var weapon_profiles: Array = []
var player_spread_degrees := PackedFloat32Array()
var player_spread_profile := PackedInt32Array()
var pending_events: Array = []

func _init() -> void:
	rng = DeterministicRngScript.new()
	grid = FlowFieldGridScript.new()
	flow_field = FlowFieldScript.new()
	player_position_quantized.resize(MAX_PLAYER_SLOTS * 2)
	player_position_quantized.fill(0)
	player_alive.resize(MAX_PLAYER_SLOTS)
	player_alive.fill(0)
	player_present.resize(MAX_PLAYER_SLOTS)
	player_present.fill(0)
	player_spread_degrees.resize(MAX_PLAYER_SLOTS)
	player_spread_degrees.fill(0.0)
	player_spread_profile.resize(MAX_PLAYER_SLOTS)
	player_spread_profile.fill(-1)

func configure(
	grid_origin_xz: Vector2,
	grid_cell_size: float,
	grid_width: int,
	grid_height: int
) -> void:
	grid.configure(grid_origin_xz, grid_cell_size, grid_width, grid_height)
	flow_field.setup(grid)

## 清空全部实体状态并按房间种子重置随机流。阻挡网格保留（静态几何不随开局变化）。
func reset(room_seed: int) -> void:
	rng.seed_streams(room_seed)
	tick_index = 0
	next_entity_id = 1
	zombie_id = PackedInt32Array()
	zombie_position = PackedVector2Array()
	zombie_height = PackedFloat32Array()
	zombie_facing = PackedFloat32Array()
	zombie_health = PackedInt32Array()
	zombie_state = PackedByteArray()
	zombie_target_slot = PackedByteArray()
	zombie_max_health = PackedInt32Array()
	zombie_previous_position = PackedVector2Array()
	zombie_previous_height = PackedFloat32Array()
	zombie_previous_facing = PackedFloat32Array()
	zombie_velocity = PackedVector2Array()
	zombie_vertical_velocity = PackedFloat32Array()
	zombie_radius = PackedFloat32Array()
	zombie_home = PackedVector2Array()
	zombie_wander_target = PackedVector2Array()
	zombie_wander_pause_ticks = PackedInt32Array()
	zombie_hit_stun_ticks = PackedInt32Array()
	zombie_move_speed = PackedFloat32Array()
	zombie_attack_state = PackedInt32Array()
	player_position_quantized.fill(0)
	player_alive.fill(0)
	player_present.fill(0)
	pending_spawn_waves = []
	pending_events = []
	player_spread_degrees.fill(0.0)
	player_spread_profile.fill(-1)
	pending_spawn_capacity = 0
	_clear_tick_events()
	grid.mark_dirty()
	flow_field.setup(grid)

func set_default_move_speed(value: float) -> void:
	default_move_speed = maxf(value, 0.0)

## 感知半径由装配方注入（DemoArena 传入 wave_perception_range，基线默认 60.0）。
func set_perception_range(value: float) -> void:
	perception_range = maxf(value, 0.0)

func get_rng() -> DeterministicRng:
	return rng

func get_grid() -> FlowFieldGrid:
	return grid

func get_flow_field() -> FlowField:
	return flow_field

func get_tick() -> int:
	return tick_index

func get_zombie_count() -> int:
	return zombie_id.size()

func get_next_entity_id() -> int:
	return next_entity_id

func get_pending_spawn_capacity() -> int:
	return pending_spawn_capacity

func get_zombie_id_array() -> PackedInt32Array:
	return zombie_id

## id 单调递增且数组保持顺序，因此可以直接二分。
func index_of_zombie(zombie_id_value: int) -> int:
	var index := zombie_id.bsearch(zombie_id_value, true)
	if index < 0 or index >= zombie_id.size():
		return -1
	return index if zombie_id[index] == zombie_id_value else -1

func get_zombie_position(index: int) -> Vector2:
	return zombie_position[index]

func get_zombie_previous_position(index: int) -> Vector2:
	return zombie_previous_position[index]

func get_zombie_height(index: int) -> float:
	return zombie_height[index]

func get_zombie_previous_height(index: int) -> float:
	return zombie_previous_height[index]

func get_zombie_facing(index: int) -> float:
	return zombie_facing[index]

func get_zombie_previous_facing(index: int) -> float:
	return zombie_previous_facing[index]

func get_zombie_state(index: int) -> int:
	return zombie_state[index]

func get_zombie_health(index: int) -> int:
	return zombie_health[index]

func get_zombie_max_health(index: int) -> int:
	return zombie_max_health[index]

## 实体 id 由单调递增计数器分配，永不复用。
func spawn_zombie(
	position_xz: Vector2,
	facing_yaw: float,
	max_health_points: float
) -> int:
	var new_id := next_entity_id
	next_entity_id += 1
	var health_points := maxi(
		roundi(maxf(max_health_points, 0.0) * float(HEALTH_SCALE)),
		1
	)
	zombie_id.append(new_id)
	zombie_position.append(position_xz)
	zombie_height.append(0.0)
	zombie_facing.append(facing_yaw)
	zombie_health.append(health_points)
	zombie_state.append(ZombieBehaviorMathScript.State.WANDER)
	zombie_target_slot.append(NO_TARGET_SLOT)
	zombie_max_health.append(health_points)
	zombie_previous_position.append(position_xz)
	zombie_previous_height.append(0.0)
	zombie_previous_facing.append(facing_yaw)
	zombie_velocity.append(Vector2.ZERO)
	zombie_vertical_velocity.append(0.0)
	zombie_radius.append(ZOMBIE_RADIUS)
	zombie_home.append(position_xz)
	zombie_wander_target.append(position_xz)
	zombie_wander_pause_ticks.append(0)
	zombie_hit_stun_ticks.append(0)
	zombie_move_speed.append(default_move_speed)
	for _state_slot in range(MeleeAttackCycleScript.STATE_SIZE):
		zombie_attack_state.append(0)
	tick_spawn_events.append(new_id)
	_select_wander_target(zombie_id.size() - 1)
	return new_id

## 波次生成的全部随机取自 Stream.ZOMBIE_SPAWN，并在下一 tick 开头统一执行，
## 使「哪一 tick 生成了哪些僵尸」本身也是确定的。
func queue_spawn_wave(
	centers: PackedVector2Array,
	minimum_per_center: int,
	maximum_per_center: int,
	capacity: int,
	radius: float,
	minimum_spacing: float,
	max_health_points: float
) -> void:
	pending_spawn_waves.append({
		"centers": centers.duplicate(),
		"minimum_per_center": minimum_per_center,
		"maximum_per_center": maximum_per_center,
		"capacity": capacity,
		"radius": radius,
		"minimum_spacing": minimum_spacing,
		"max_health_points": max_health_points,
	})
	pending_spawn_capacity += maxi(capacity, 0)

func set_player_snapshot(
	slot: int,
	position_xz: Vector2,
	alive: bool,
	present: bool
) -> void:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	player_position_quantized[slot * 2] = roundi(position_xz.x * POSITION_QUANTIZATION)
	player_position_quantized[slot * 2 + 1] = roundi(position_xz.y * POSITION_QUANTIZATION)
	player_alive[slot] = 1 if alive else 0
	player_present[slot] = 1 if present else 0

func get_player_position(slot: int) -> Vector2:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return Vector2.ZERO
	return Vector2(
		float(player_position_quantized[slot * 2]) / POSITION_QUANTIZATION,
		float(player_position_quantized[slot * 2 + 1]) / POSITION_QUANTIZATION
	)

func is_player_alive(slot: int) -> bool:
	return slot >= 0 and slot < MAX_PLAYER_SLOTS and player_alive[slot] == 1

func is_player_present(slot: int) -> bool:
	return slot >= 0 and slot < MAX_PLAYER_SLOTS and player_present[slot] == 1

## 任何运行时增删阻挡几何的系统都必须调用它，否则流场会停留在过期的通行图上。
func set_blocker_world_rect(min_xz: Vector2, max_xz: Vector2, blocked: bool) -> void:
	grid.set_blocked_world_rect(min_xz, max_xz, blocked)

## 整数 Bresenham 逐 cell 判定视线；终点 cell 自身不算阻挡。
func line_is_clear(from_xz: Vector2, to_xz: Vector2) -> bool:
	var from_cell := grid.world_to_cell(from_xz)
	var to_cell := grid.world_to_cell(to_xz)
	var delta_x := absi(to_cell.x - from_cell.x)
	var delta_y := absi(to_cell.y - from_cell.y)
	var step_x := 1 if to_cell.x >= from_cell.x else -1
	var step_y := 1 if to_cell.y >= from_cell.y else -1
	var error := delta_x - delta_y
	var current := from_cell
	for _step_index in range(delta_x + delta_y + 1):
		if current == to_cell:
			return true
		if current != from_cell and grid.is_blocked(current):
			return false
		var doubled_error := error * 2
		if doubled_error > -delta_y:
			error -= delta_y
			current.x += step_x
		if doubled_error < delta_x:
			error += delta_x
			current.y += step_y
	return true

## 唯一的僵尸掉血入口。damage_points 已是 HEALTH_SCALE 单位的整数。
func apply_zombie_damage(
	index: int,
	damage_points: int,
	hit_position: Vector2,
	hit_height: float,
	direction: Vector2,
	zone: StringName
) -> bool:
	if index < 0 or index >= zombie_id.size():
		return false
	if zombie_state[index] == STATE_DEAD:
		return false
	var applied := mini(maxi(damage_points, 0), zombie_health[index])
	if applied <= 0:
		return false
	zombie_health[index] -= applied
	var impulse := HitResponseMathScript.knockback_velocity(
		Vector3(direction.x, 0.0, direction.y),
		ZOMBIE_KNOCKBACK_IMPULSE,
		1.0,
		ZOMBIE_KNOCKBACK_VERTICAL_BIAS
	)
	zombie_velocity[index] += Vector2(impulse.x, impulse.z)
	zombie_vertical_velocity[index] += impulse.y
	var killed := zombie_health[index] <= 0
	if not killed:
		zombie_hit_stun_ticks[index] = ZOMBIE_HIT_STUN_TICKS
		MeleeAttackCycleScript.cancel_state(
			zombie_attack_state,
			index * MeleeAttackCycleScript.STATE_SIZE
		)
	tick_hit_events.append({
		"zombie_id": zombie_id[index],
		"position": hit_position,
		"height": hit_height,
		"direction": direction,
		"damage": float(applied) / float(HEALTH_SCALE),
		"zone": zone,
		"killed": killed,
	})
	if killed:
		zombie_state[index] = STATE_DEAD
		zombie_radius[index] = 0.0
		zombie_velocity[index] = Vector2.ZERO
		tick_death_events.append(zombie_id[index])
	return true

## 推进一个模拟 tick。不接收任何真实帧时长形参：时间步长恒为 SimClock.TICK_SECONDS。
## 顺序固定：生成 -> 散布回复 -> 玩家事件结算 -> 流场 -> 僵尸推进 ->
## 碰撞 -> 僵尸攻击 -> 压缩删除。任何调整都会改变哈希序列，必须同步全端。
func step_tick() -> void:
	tick_index += 1
	_clear_tick_events()
	_apply_pending_spawn_waves()
	_recover_spread()
	_resolve_pending_events()
	_update_flow_field()
	_update_zombies()
	_resolve_collisions()
	_resolve_zombie_attacks()
	_compact_dead()

func _clear_tick_events() -> void:
	tick_hit_events = []
	tick_death_events = PackedInt32Array()
	tick_spawn_events = PackedInt32Array()
	tick_player_damage_events = []
	tick_shot_events = []

func _apply_pending_spawn_waves() -> void:
	pending_spawn_capacity = 0
	if pending_spawn_waves.is_empty():
		return
	var waves := pending_spawn_waves
	pending_spawn_waves = []
	for wave in waves:
		_spawn_wave(wave)

func _spawn_wave(wave: Dictionary) -> int:
	var spawn_stream: int = DeterministicRngScript.Stream.ZOMBIE_SPAWN
	var centers: PackedVector2Array = wave["centers"]
	var capacity: int = maxi(int(wave["capacity"]), 0)
	var radius: float = maxf(float(wave["radius"]), 0.0)
	var minimum_spacing: float = maxf(float(wave["minimum_spacing"]), 0.0)
	var max_health_points: float = float(wave["max_health_points"])
	var occupied := zombie_position.duplicate()
	var spawned := 0
	for center in centers:
		var requested := rng.next_int_range(
			spawn_stream,
			int(wave["minimum_per_center"]),
			int(wave["maximum_per_center"])
		)
		for _spawn_index in range(requested):
			if spawned >= capacity:
				return spawned
			var spawn_position := _sample_spawn_position(
				center, radius, minimum_spacing, occupied
			)
			var facing := rng.next_range(spawn_stream, 0.0, TAU)
			spawn_zombie(spawn_position, facing, max_health_points)
			occupied.append(spawn_position)
			spawned += 1
	return spawned

func _sample_spawn_position(
	center: Vector2,
	radius: float,
	minimum_spacing: float,
	occupied: PackedVector2Array
) -> Vector2:
	var spawn_stream: int = DeterministicRngScript.Stream.ZOMBIE_SPAWN
	var fallback := center
	for _attempt in range(16):
		var angle := rng.next_range(spawn_stream, 0.0, TAU)
		var sample_radius := sqrt(rng.next_unit_float(spawn_stream)) * radius
		var candidate := center + Vector2(
			cos(angle) * sample_radius,
			sin(angle) * sample_radius
		)
		fallback = candidate
		if _has_spawn_clearance(candidate, minimum_spacing, occupied):
			return candidate
	return fallback

func _has_spawn_clearance(
	candidate: Vector2,
	minimum_spacing: float,
	occupied: PackedVector2Array
) -> bool:
	for position in occupied:
		if candidate.distance_to(position) < minimum_spacing:
			return false
	return true

func _update_flow_field() -> void:
	var sources := PackedInt32Array()
	for slot in range(MAX_PLAYER_SLOTS):
		if player_present[slot] == 0 or player_alive[slot] == 0:
			continue
		var cell_index := grid.cell_index(grid.world_to_cell(get_player_position(slot)))
		if cell_index >= 0 and not sources.has(cell_index):
			sources.append(cell_index)
	sources.sort()
	flow_field.update(sources)

func _update_zombies() -> void:
	var count := zombie_id.size()
	var tick_seconds := SimClockScript.TICK_SECONDS
	for index in range(count):
		if zombie_state[index] == STATE_DEAD:
			continue
		zombie_previous_position[index] = zombie_position[index]
		zombie_previous_facing[index] = zombie_facing[index]
		zombie_previous_height[index] = zombie_height[index]
		zombie_hit_stun_ticks[index] = maxi(zombie_hit_stun_ticks[index] - 1, 0)

		var position := zombie_position[index]
		var target_slot := _select_target_slot(position, int(zombie_target_slot[index]))
		zombie_target_slot[index] = target_slot
		var target_alive := target_slot != NO_TARGET_SLOT
		var target_position := Vector2.ZERO
		var direction_to_target := Vector2.ZERO
		var distance_to_target := INF
		if target_alive:
			target_position = get_player_position(target_slot)
			direction_to_target = target_position - position
			distance_to_target = direction_to_target.length()
			if distance_to_target > 0.001:
				direction_to_target /= distance_to_target
		var attack_path_clear := (
			target_alive and
			distance_to_target <= ZOMBIE_ATTACK_RANGE and
			line_is_clear(position, target_position)
		)

		var previous_state := int(zombie_state[index])
		var next_state := ZombieBehaviorMathScript.next_state(
			previous_state,
			distance_to_target,
			target_alive,
			perception_range,
			ZOMBIE_PERCEPTION_EXIT_MARGIN,
			ZOMBIE_ATTACK_RANGE,
			attack_path_clear
		)
		zombie_state[index] = next_state
		if (
			previous_state == ZombieBehaviorMathScript.State.ATTACK and
			next_state != ZombieBehaviorMathScript.State.ATTACK
		):
			MeleeAttackCycleScript.cancel_state(
				zombie_attack_state,
				index * MeleeAttackCycleScript.STATE_SIZE
			)

		var target_velocity := Vector2.ZERO
		if zombie_hit_stun_ticks[index] <= 0:
			if next_state == ZombieBehaviorMathScript.State.WANDER:
				target_velocity = _wander_velocity(index)
			elif next_state == ZombieBehaviorMathScript.State.AWARE_APPROACH:
				target_velocity = _approach_velocity(
					index, distance_to_target, direction_to_target, attack_path_clear
				)

		var facing_direction := direction_to_target
		if (
			next_state == ZombieBehaviorMathScript.State.WANDER or
			(
				next_state == ZombieBehaviorMathScript.State.AWARE_APPROACH and
				target_velocity.length_squared() > 0.0001
			)
		):
			facing_direction = target_velocity
		if facing_direction.length_squared() > 0.0001:
			zombie_facing[index] = ZombieBehaviorMathScript.facing_yaw(
				Vector3(facing_direction.x, 0.0, facing_direction.y),
				zombie_facing[index]
			)

		var moving := target_velocity.length_squared() > 0.0001
		var rate := ZOMBIE_MOVE_ACCELERATION if moving else ZOMBIE_GROUND_DRAG
		var velocity := zombie_velocity[index]
		velocity.x = move_toward(velocity.x, target_velocity.x, rate * tick_seconds)
		velocity.y = move_toward(velocity.y, target_velocity.y, rate * tick_seconds)
		zombie_velocity[index] = velocity
		zombie_position[index] = position + velocity * tick_seconds

		var vertical_velocity := zombie_vertical_velocity[index]
		var height := zombie_height[index]
		if height > 0.0 or vertical_velocity > 0.0:
			vertical_velocity -= SIM_GRAVITY * tick_seconds
			height += vertical_velocity * tick_seconds
			if height <= 0.0:
				height = 0.0
				vertical_velocity = 0.0
		zombie_height[index] = height
		zombie_vertical_velocity[index] = vertical_velocity

## ZombieTargetSelector 语义在玩家槽位快照上的复刻：最近优先，
## 切换必须比当前目标近出 ZOMBIE_TARGET_SWITCH_MARGIN 才生效。
func _select_target_slot(position: Vector2, current_slot: int) -> int:
	var best_slot := NO_TARGET_SLOT
	var best_distance := INF
	if _slot_is_candidate(current_slot, position):
		best_slot = current_slot
		best_distance = position.distance_to(get_player_position(current_slot))
	for slot in range(MAX_PLAYER_SLOTS):
		if not _slot_is_candidate(slot, position):
			continue
		var distance := position.distance_to(get_player_position(slot))
		if distance + ZOMBIE_TARGET_SWITCH_MARGIN < best_distance:
			best_slot = slot
			best_distance = distance
	return best_slot

func _slot_is_candidate(slot: int, position: Vector2) -> bool:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return false
	if player_present[slot] == 0 or player_alive[slot] == 0:
		return false
	return position.distance_to(get_player_position(slot)) <= perception_range

func _select_wander_target(index: int) -> void:
	var wander_stream: int = DeterministicRngScript.Stream.ZOMBIE_WANDER
	var angle := rng.next_range(wander_stream, 0.0, TAU)
	var distance_ratio := rng.next_range(wander_stream, 0.35, 1.0)
	var home := zombie_home[index]
	var point := ZombieBehaviorMathScript.wander_point(
		Vector3(home.x, 0.0, home.y),
		angle,
		distance_ratio,
		ZOMBIE_WANDER_RADIUS
	)
	zombie_wander_target[index] = Vector2(point.x, point.z)

func _wander_velocity(index: int) -> Vector2:
	if zombie_wander_pause_ticks[index] > 0:
		zombie_wander_pause_ticks[index] -= 1
		if zombie_wander_pause_ticks[index] <= 0:
			_select_wander_target(index)
		return Vector2.ZERO
	var position := zombie_position[index]
	var target := zombie_wander_target[index]
	var velocity_3d := ZombieBehaviorMathScript.arrive_velocity(
		Vector3(position.x, 0.0, position.y),
		Vector3(target.x, 0.0, target.y),
		ZOMBIE_WANDER_ARRIVE_RANGE,
		ZOMBIE_WANDER_SPEED,
		ZOMBIE_WANDER_SLOW_RADIUS
	)
	var velocity := Vector2(velocity_3d.x, velocity_3d.z)
	if velocity == Vector2.ZERO:
		zombie_wander_pause_ticks[index] = rng.next_int_range(
			DeterministicRngScript.Stream.ZOMBIE_WANDER,
			ZOMBIE_WANDER_PAUSE_MIN_TICKS,
			ZOMBIE_WANDER_PAUSE_MAX_TICKS
		)
	return velocity

## 追击只查自己所在 cell 的方向向量，成本与僵尸数量无关。
## 流场不可达（例如被临时封死）时退回直线方向，行为与旧的导航不可用回退一致。
func _approach_velocity(
	index: int,
	distance_to_target: float,
	direction_to_target: Vector2,
	attack_path_clear: bool
) -> Vector2:
	var stop_range := ZombieBehaviorMathScript.approach_stop_range(
		distance_to_target, ZOMBIE_ATTACK_RANGE, attack_path_clear
	)
	var gap := distance_to_target - stop_range
	if gap <= 0.0:
		return Vector2.ZERO
	var speed_factor := clampf(gap / ZOMBIE_PERCEPTION_SLOW_RADIUS, 0.25, 1.0)
	var direction := flow_field.get_direction(
		grid.world_to_cell(zombie_position[index])
	)
	if direction.length_squared() <= 0.0001:
		direction = direction_to_target
	if direction.length_squared() <= 0.0001:
		return Vector2.ZERO
	return direction.normalized() * zombie_move_speed[index] * speed_factor

func _resolve_collisions() -> void:
	var count := zombie_id.size()
	if count == 0:
		return
	var displacement := SimCollisionScript.accumulate_separation(
		zombie_position,
		zombie_radius,
		count,
		SimCollisionScript.DEFAULT_HASH_CELL_SIZE,
		ZOMBIE_SEPARATION_RATIO
	)
	for index in range(count):
		if zombie_state[index] == STATE_DEAD:
			continue
		var radius := zombie_radius[index]
		var position := zombie_position[index] + displacement[index]
		for slot in range(MAX_PLAYER_SLOTS):
			if player_present[slot] == 0 or player_alive[slot] == 0:
				continue
			position += SimCollisionScript.resolve_circle_push(
				position, radius, get_player_position(slot), PLAYER_RADIUS
			)
		position += SimCollisionScript.resolve_blocker(position, radius, grid)
		zombie_position[index] = position

func _resolve_zombie_attacks() -> void:
	var count := zombie_id.size()
	for index in range(count):
		if zombie_state[index] == STATE_DEAD:
			continue
		var target_slot := int(zombie_target_slot[index])
		var target_alive := target_slot != NO_TARGET_SLOT and is_player_alive(target_slot)
		var target_in_range := false
		if target_alive:
			target_in_range = (
				zombie_state[index] == ZombieBehaviorMathScript.State.ATTACK and
				zombie_position[index].distance_to(get_player_position(target_slot))
					<= ZOMBIE_ATTACK_RANGE and
				zombie_hit_stun_ticks[index] <= 0
			)
		var outcome := MeleeAttackCycleScript.tick_state(
			zombie_attack_state,
			index * MeleeAttackCycleScript.STATE_SIZE,
			ZOMBIE_ATTACK_COOLDOWN_TICKS,
			ZOMBIE_ATTACK_WINDUP_TICKS,
			target_in_range,
			target_alive
		)
		if outcome == MeleeAttackCycleScript.TickOutcome.WINDUP_STARTED:
			tick_player_damage_events.append({
				"kind": &"zombie_windup",
				"zombie_id": zombie_id[index],
				"slot": target_slot,
				"damage": 0.0,
				"origin": zombie_position[index],
			})
		elif outcome == MeleeAttackCycleScript.TickOutcome.ATTACK_LANDED:
			tick_player_damage_events.append({
				"kind": &"zombie_hit",
				"zombie_id": zombie_id[index],
				"slot": target_slot,
				"damage": ZOMBIE_ATTACK_DAMAGE,
				"origin": zombie_position[index],
			})

## 按顺序压缩删除，保证下标顺序始终等于 id 升序。
func _compact_dead() -> void:
	var count := zombie_id.size()
	var survivor_count := 0
	for index in range(count):
		if zombie_state[index] != STATE_DEAD:
			survivor_count += 1
	if survivor_count == count:
		return
	var new_id := PackedInt32Array()
	var new_position := PackedVector2Array()
	var new_height := PackedFloat32Array()
	var new_facing := PackedFloat32Array()
	var new_health := PackedInt32Array()
	var new_state := PackedByteArray()
	var new_target_slot := PackedByteArray()
	var new_max_health := PackedInt32Array()
	var new_previous_position := PackedVector2Array()
	var new_previous_height := PackedFloat32Array()
	var new_previous_facing := PackedFloat32Array()
	var new_velocity := PackedVector2Array()
	var new_vertical_velocity := PackedFloat32Array()
	var new_radius := PackedFloat32Array()
	var new_home := PackedVector2Array()
	var new_wander_target := PackedVector2Array()
	var new_wander_pause_ticks := PackedInt32Array()
	var new_hit_stun_ticks := PackedInt32Array()
	var new_move_speed := PackedFloat32Array()
	var new_attack_state := PackedInt32Array()
	for index in range(count):
		if zombie_state[index] == STATE_DEAD:
			continue
		new_id.append(zombie_id[index])
		new_position.append(zombie_position[index])
		new_height.append(zombie_height[index])
		new_facing.append(zombie_facing[index])
		new_health.append(zombie_health[index])
		new_state.append(zombie_state[index])
		new_target_slot.append(zombie_target_slot[index])
		new_max_health.append(zombie_max_health[index])
		new_previous_position.append(zombie_previous_position[index])
		new_previous_height.append(zombie_previous_height[index])
		new_previous_facing.append(zombie_previous_facing[index])
		new_velocity.append(zombie_velocity[index])
		new_vertical_velocity.append(zombie_vertical_velocity[index])
		new_radius.append(zombie_radius[index])
		new_home.append(zombie_home[index])
		new_wander_target.append(zombie_wander_target[index])
		new_wander_pause_ticks.append(zombie_wander_pause_ticks[index])
		new_hit_stun_ticks.append(zombie_hit_stun_ticks[index])
		new_move_speed.append(zombie_move_speed[index])
		for state_slot in range(MeleeAttackCycleScript.STATE_SIZE):
			new_attack_state.append(
				zombie_attack_state[index * MeleeAttackCycleScript.STATE_SIZE + state_slot]
			)
	zombie_id = new_id
	zombie_position = new_position
	zombie_height = new_height
	zombie_facing = new_facing
	zombie_health = new_health
	zombie_state = new_state
	zombie_target_slot = new_target_slot
	zombie_max_health = new_max_health
	zombie_previous_position = new_previous_position
	zombie_previous_height = new_previous_height
	zombie_previous_facing = new_previous_facing
	zombie_velocity = new_velocity
	zombie_vertical_velocity = new_vertical_velocity
	zombie_radius = new_radius
	zombie_home = new_home
	zombie_wander_target = new_wander_target
	zombie_wander_pause_ticks = new_wander_pause_ticks
	zombie_hit_stun_ticks = new_hit_stun_ticks
	zombie_move_speed = new_move_speed
	zombie_attack_state = new_attack_state

## ---- 武器档案 ----
## 由表现层在装配时按 weapon_id 注册；模拟层只认下标，不认资源。
func configure_weapon_profile(
	profile_index: int,
	damage: float,
	attack_range: float,
	base_spread_degrees: float,
	max_spread_degrees: float,
	spread_increase_degrees: float,
	spread_recovery_degrees_per_second: float,
	max_penetration_count: int,
	penetration_damage_coefficient: float
) -> void:
	if profile_index < 0:
		return
	while weapon_profiles.size() <= profile_index:
		weapon_profiles.append({})
	weapon_profiles[profile_index] = {
		"damage": maxf(damage, 0.0),
		"attack_range": maxf(attack_range, 0.0),
		"base_spread_degrees": maxf(base_spread_degrees, 0.0),
		"max_spread_degrees": maxf(max_spread_degrees, maxf(base_spread_degrees, 0.0)),
		"spread_increase_degrees": maxf(spread_increase_degrees, 0.0),
		"spread_recovery_degrees_per_second": maxf(spread_recovery_degrees_per_second, 0.0),
		"max_penetration_count": clampi(max_penetration_count, 0, 16),
		"penetration_damage_coefficient": clampf(penetration_damage_coefficient, 0.0, 1.0),
	}

## 开火事件只携带玩家的瞄准方向，不携带散布后的方向。
## 散布由各客户端在 Stream.WEAPON_SPREAD 上各自确定性地算出。
func queue_fire_event(
	slot: int,
	profile_index: int,
	origin_xz: Vector2,
	origin_height: float,
	aim_direction: Vector2
) -> void:
	pending_events.append({
		"kind": &"shot",
		"slot": slot,
		"profile_index": profile_index,
		"origin": origin_xz,
		"origin_height": origin_height,
		"aim_direction": aim_direction,
	})

func queue_melee_event(
	slot: int,
	damage: float,
	reach: float,
	half_width: float,
	origin_xz: Vector2,
	origin_height: float,
	aim_direction: Vector2
) -> void:
	pending_events.append({
		"kind": &"melee",
		"slot": slot,
		"damage": damage,
		"reach": reach,
		"half_width": half_width,
		"origin": origin_xz,
		"origin_height": origin_height,
		"aim_direction": aim_direction,
	})

func queue_explosion_event(
	origin_xz: Vector2,
	origin_height: float,
	radius: float,
	center_damage: float,
	edge_damage: float
) -> void:
	pending_events.append({
		"kind": &"explosion",
		"origin": origin_xz,
		"origin_height": origin_height,
		"radius": radius,
		"center_damage": center_damage,
		"edge_damage": edge_damage,
	})

## profile_index 必须是「换上」的那把武器的档案下标，不是被换下的那把。
func queue_spread_reset(slot: int, profile_index: int) -> void:
	pending_events.append({
		"kind": &"spread_reset",
		"slot": slot,
		"profile_index": profile_index,
	})

## 把槽位的散布重置为 profile_index 这把武器自己的基础散布。
## 必须先落档案再取 base：player_spread_profile[slot] 记录的是「上一次开火用的档案」，
## 换装后若沿用旧下标，就会把新武器重置到旧武器的 base。
## 基线里每把 RangedWeapon 各自持有一个 WeaponSpreadState（构造即 current = base，
## 收起时 reset() 回 base），所以换上任何一把枪，它的当前散布都恰为自己的 base。
func reset_spread(slot: int, profile_index: int) -> void:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	player_spread_profile[slot] = profile_index
	player_spread_degrees[slot] = float(
		_weapon_profile(profile_index).get("base_spread_degrees", 0.0)
	)

func get_spread_degrees(slot: int) -> float:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return 0.0
	return player_spread_degrees[slot]

func _weapon_profile(profile_index: int) -> Dictionary:
	if profile_index < 0 or profile_index >= weapon_profiles.size():
		return {}
	return weapon_profiles[profile_index]

func _recover_spread() -> void:
	for slot in range(MAX_PLAYER_SLOTS):
		var profile := _weapon_profile(player_spread_profile[slot])
		if profile.is_empty():
			continue
		player_spread_degrees[slot] = WeaponSpreadStateScript.recovered_degrees(
			player_spread_degrees[slot],
			float(profile["base_spread_degrees"]),
			float(profile["spread_recovery_degrees_per_second"]),
			SimClockScript.TICK_SECONDS
		)

func _resolve_pending_events() -> void:
	if pending_events.is_empty():
		return
	var events := pending_events
	pending_events = []
	for event in events:
		var kind: StringName = event["kind"]
		if kind == &"shot":
			_resolve_shot_event(event)
		elif kind == &"melee":
			_resolve_melee_event(event)
		elif kind == &"explosion":
			_resolve_explosion_event(event)
		elif kind == &"spread_reset":
			reset_spread(int(event["slot"]), int(event["profile_index"]))

func _resolve_shot_event(event: Dictionary) -> void:
	var slot := int(event["slot"])
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	var profile_index := int(event["profile_index"])
	var profile := _weapon_profile(profile_index)
	if profile.is_empty():
		return
	# 该槽位第一次用这个档案开火（或换装事件没排上队就直接开火）时，
	# 散布必须先落到这把武器自己的 base：基线的 WeaponSpreadState 构造即
	# current = base，第一发绝不可能是 0 度。
	if player_spread_profile[slot] != profile_index:
		reset_spread(slot, profile_index)
	var origin: Vector2 = event["origin"]
	var origin_height: float = event["origin_height"]
	var aim: Vector2 = event["aim_direction"]
	if aim.length_squared() <= 0.000001:
		aim = Vector2(0.0, -1.0)
	aim = aim.normalized()

	var spread_degrees := player_spread_degrees[slot]
	var offset := rng.next_range(
		DeterministicRngScript.Stream.WEAPON_SPREAD, -1.0, 1.0
	)
	var direction := WeaponSpreadStateScript.spread_direction(
		aim, spread_degrees, offset
	)
	player_spread_degrees[slot] = WeaponSpreadStateScript.increased_degrees(
		spread_degrees,
		float(profile["spread_increase_degrees"]),
		float(profile["max_spread_degrees"])
	)

	var attack_range := float(profile["attack_range"])
	var maximum_targets := int(profile["max_penetration_count"]) + 1
	var coefficient := float(profile["penetration_damage_coefficient"])
	var hits := SimCombatScript.resolve_ray_hits(
		self, origin, origin_height, direction, attack_range, maximum_targets
	)
	var end_position := origin + direction * attack_range
	var did_hit := false
	var killed := false
	var total_damage := 0.0
	var zone: StringName = &""
	var current_damage := float(profile["damage"])
	for hit in hits:
		var index := int(hit["index"])
		var hit_zone: StringName = hit["zone"]
		var multiplier := SimHitGeometryScript.damage_multiplier(hit_zone)
		var damage_points := roundi(current_damage * multiplier * float(HEALTH_SCALE))
		var before_health := zombie_health[index]
		if apply_zombie_damage(
			index, damage_points, hit["point"], hit["height"], direction, hit_zone
		):
			did_hit = true
			zone = hit_zone
			total_damage += float(before_health - zombie_health[index]) / float(HEALTH_SCALE)
			killed = killed or zombie_state[index] == STATE_DEAD
		# 曳光终点始终落在最后一个被处理的命中点；穿透关闭时即第一个命中点。
		end_position = hit["point"]
		if coefficient <= 0.0:
			break
		current_damage *= coefficient
	tick_shot_events.append({
		"slot": slot,
		"origin": origin,
		"origin_height": origin_height,
		"direction": direction,
		"end": end_position,
		"end_height": origin_height,
		"did_hit": did_hit,
		"killed": killed,
		"damage": total_damage,
		"zone": zone,
	})

func _resolve_melee_event(event: Dictionary) -> void:
	var slot := int(event["slot"])
	var origin: Vector2 = event["origin"]
	var origin_height: float = event["origin_height"]
	var aim: Vector2 = event["aim_direction"]
	if aim.length_squared() <= 0.000001:
		aim = Vector2(0.0, -1.0)
	aim = aim.normalized()
	var index := SimCombatScript.resolve_melee_target(
		self,
		origin,
		origin_height,
		aim,
		float(event["reach"]),
		float(event["half_width"])
	)
	var did_hit := false
	var killed := false
	var damage_dealt := 0.0
	var end_position := origin + aim * float(event["reach"])
	var end_height := origin_height
	if index >= 0:
		var hit_height := SimHitGeometryScript.aim_point_height(
			get_zombie_height(index)
		)
		var before_health := zombie_health[index]
		var damage_points := roundi(float(event["damage"]) * float(HEALTH_SCALE))
		if apply_zombie_damage(
			index,
			damage_points,
			get_zombie_position(index),
			hit_height,
			aim,
			SimHitGeometryScript.ZONE_BODY
		):
			did_hit = true
			killed = zombie_state[index] == STATE_DEAD
			damage_dealt = float(before_health - zombie_health[index]) / float(HEALTH_SCALE)
		end_position = get_zombie_position(index)
		end_height = hit_height
	tick_shot_events.append({
		"slot": slot,
		"origin": origin,
		"origin_height": origin_height,
		"direction": aim,
		"end": end_position,
		"end_height": end_height,
		"did_hit": did_hit,
		"killed": killed,
		"damage": damage_dealt,
		"zone": SimHitGeometryScript.ZONE_BODY if did_hit else &"",
	})

func _resolve_explosion_event(event: Dictionary) -> void:
	var targets := SimCombatScript.resolve_explosion_targets(
		self,
		event["origin"],
		float(event["origin_height"]),
		float(event["radius"]),
		float(event["center_damage"]),
		float(event["edge_damage"])
	)
	for target in targets:
		apply_zombie_damage(
			int(target["index"]),
			roundi(float(target["damage"]) * float(HEALTH_SCALE)),
			target["point"],
			float(target["height"]),
			target["direction"],
			SimHitGeometryScript.ZONE_BODY
		)
