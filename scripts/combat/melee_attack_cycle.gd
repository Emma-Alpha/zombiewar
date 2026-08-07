extends RefCounted
class_name MeleeAttackCycle

var cooldown_duration: float
var windup_duration: float
var cooldown_remaining := 0.0
var windup_remaining := 0.0
var pending := false

func _init(cooldown_seconds: float, windup_seconds: float) -> void:
	cooldown_duration = maxf(cooldown_seconds, 0.01)
	windup_duration = maxf(windup_seconds, 0.0)

func tick(delta: float, target_in_range: bool, target_alive: bool) -> bool:
	var safe_delta := maxf(delta, 0.0)
	cooldown_remaining = maxf(cooldown_remaining - safe_delta, 0.0)
	if pending:
		windup_remaining = maxf(windup_remaining - safe_delta, 0.0)
		if windup_remaining <= 0.0:
			pending = false
			return target_in_range and target_alive
	if not pending and target_in_range and target_alive and cooldown_remaining <= 0.0:
		pending = true
		windup_remaining = windup_duration
		cooldown_remaining = cooldown_duration
	return false

func is_winding_up() -> bool:
	return pending

func cancel_pending() -> void:
	pending = false
	windup_remaining = 0.0

## ---- 模拟层：基于 tick 的无分配变体 ----
## 300 只僵尸各自持有一个 MeleeAttackCycle 实例会带来 300 次分配与
## 不确定的对象顺序，因此模拟层把周期状态放进 SimWorld 的 PackedInt32Array，
## 由下面这组静态函数原地推进。语义与上面的实例版本逐条对应。
const STATE_COOLDOWN := 0
const STATE_WINDUP := 1
const STATE_PENDING := 2
const STATE_SIZE := 3

enum TickOutcome {
	NONE,
	WINDUP_STARTED,
	ATTACK_LANDED,
}

static func ticks_for_seconds(seconds: float, tick_seconds: float) -> int:
	return maxi(int(ceil(maxf(seconds, 0.0) / maxf(tick_seconds, 0.000001))), 0)

static func tick_state(
	state: PackedInt32Array,
	offset: int,
	cooldown_ticks: int,
	windup_ticks: int,
	target_in_range: bool,
	target_alive: bool
) -> int:
	var cooldown_remaining := maxi(state[offset + STATE_COOLDOWN] - 1, 0)
	state[offset + STATE_COOLDOWN] = cooldown_remaining
	if state[offset + STATE_PENDING] == 1:
		var windup_remaining := maxi(state[offset + STATE_WINDUP] - 1, 0)
		state[offset + STATE_WINDUP] = windup_remaining
		if windup_remaining > 0:
			return TickOutcome.NONE
		state[offset + STATE_PENDING] = 0
		if target_in_range and target_alive:
			return TickOutcome.ATTACK_LANDED
		return TickOutcome.NONE
	if target_in_range and target_alive and cooldown_remaining <= 0:
		state[offset + STATE_PENDING] = 1
		state[offset + STATE_WINDUP] = maxi(windup_ticks, 0)
		state[offset + STATE_COOLDOWN] = maxi(cooldown_ticks, 1)
		return TickOutcome.WINDUP_STARTED
	return TickOutcome.NONE

static func cancel_state(state: PackedInt32Array, offset: int) -> void:
	state[offset + STATE_PENDING] = 0
	state[offset + STATE_WINDUP] = 0
