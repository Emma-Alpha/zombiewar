extends SceneTree

## 验证医疗回血光环：模拟层 tick 驱动、范围内回血、范围外不回、非医疗不触发。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_medic_aura.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const SimClockScript = preload("res://scripts/sim/sim_clock.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var world := SimWorldScript.new()
	world.reset(42)

	# 两个玩家都存活、在场：slot0 是医疗（强度 1.0），slot1 是普通。
	world.set_slot_medic(0, true, 1.0)
	world.set_slot_medic(1, false, 1.0)
	world.player_alive[0] = 1
	world.player_alive[1] = 1
	world.player_present[0] = 1
	world.player_present[1] = 1

	# 医疗在原点，队友贴着站（0.5 单位内，肯定在 6.0 半径内）。
	world.player_position_quantized[0 * 2] = 0
	world.player_position_quantized[0 * 2 + 1] = 0
	world.player_position_quantized[1 * 2] = int(0.5 * SimWorldScript.POSITION_QUANTIZATION)
	world.player_position_quantized[1 * 2 + 1] = 0

	# 跑到结算点：间隔 30 tick 结算一次。
	var healed_ticks := 0
	for _i in range(SimWorldScript.MEDIC_AURA_INTERVAL_TICKS):
		world.step_tick()
		if world.tick_player_heal_events.size() > 0:
			healed_ticks += 1
	_expect(
		healed_ticks == 1,
		"范围内队友应在第 %d tick 结算到一次回血，实际 %d" % [
			SimWorldScript.MEDIC_AURA_INTERVAL_TICKS, healed_ticks
		],
		failures
	)
	# 事件内容：目标 slot1，amount = 基准 5.0 × 强度 1.0。
	if world.tick_player_heal_events.size() > 0:
		var ev: Dictionary = world.tick_player_heal_events[0]
		_expect(int(ev["slot"]) == 1, "回血事件目标应为 slot1", failures)
		_expect(
			is_equal_approx(float(ev["amount"]), 5.0),
			"回血事件 amount 应为 5.0，实际 %f" % float(ev["amount"]),
			failures
		)

	# 范围外：把队友挪到半径外（10 单位），再跑一个结算周期，不应回血。
	world.player_position_quantized[1 * 2] = int(10.0 * SimWorldScript.POSITION_QUANTIZATION)
	var far_heals := 0
	for _i in range(SimWorldScript.MEDIC_AURA_INTERVAL_TICKS):
		world.step_tick()
		far_heals += world.tick_player_heal_events.size()
	_expect(far_heals == 0, "范围外队友不应被回血，实际 %d 次" % far_heals, failures)

	# 医疗自己不回自己（target == healer 跳过）。
	if world.tick_player_heal_events.size() > 0:
		for ev in world.tick_player_heal_events:
			_expect(int(ev["slot"]) != 0, "医疗不应给自己回血", failures)

	if failures.is_empty():
		print("validate_medic_aura: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_medic_aura: %s" % failure)
	printerr("validate_medic_aura: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
