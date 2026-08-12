extends SceneTree

## 验证波间商店的属性/回血购买：扣费 + 成长表生效 + 回血事件 + 金额不足不扣。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_shop_purchase.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var world := SimWorldScript.new()
	world.reset(9)

	# 初始成长表为 1.0
	_expect(
		is_equal_approx(world.get_upgrade_scale(0, SimWorldScript.STAT_DAMAGE), 1.0),
		"初始伤害成长应为 1.0",
		failures
	)

	# 给 slot0 100 材料
	world.add_player_material(0, 100)

	# 买伤害升级：×1.1，价 30
	world.queue_shop_purchase(0, &"stat", SimWorldScript.STAT_DAMAGE, 1.1, 30)
	world.step_tick()
	_expect(
		is_equal_approx(world.get_upgrade_scale(0, SimWorldScript.STAT_DAMAGE), 1.1),
		"买伤害升级后应为 1.1",
		failures
	)
	_expect(world.get_player_material(0) == 70, "扣 30 后应剩 70", failures)

	# 金额不足：再买 100 的，不扣、成长不变
	world.queue_shop_purchase(0, &"stat", SimWorldScript.STAT_DAMAGE, 1.5, 100)
	world.step_tick()
	_expect(
		is_equal_approx(world.get_upgrade_scale(0, SimWorldScript.STAT_DAMAGE), 1.1),
		"金额不足时成长应不变",
		failures
	)
	_expect(world.get_player_material(0) == 70, "金额不足时金钱应不变", failures)

	# 买回血：产生 heal 事件
	world.queue_shop_purchase(0, &"heal", -1, 25.0, 20)
	world.step_tick()
	_expect(world.get_player_material(0) == 50, "回血扣 20 后应剩 50", failures)
	var heal_events := world.tick_player_heal_events
	var found_heal := false
	for ev in heal_events:
		if int(ev["slot"]) == 0 and is_equal_approx(float(ev["amount"]), 25.0):
			found_heal = true
			break
	_expect(found_heal, "回血购买应产生 slot0 的 heal 事件", failures)

	# 非法 stat_index 忽略
	world.add_player_material(0, 100)
	world.queue_shop_purchase(0, &"stat", 99, 2.0, 10)
	world.step_tick()
	_expect(
		is_equal_approx(world.get_upgrade_scale(0, SimWorldScript.STAT_DAMAGE), 1.1),
		"非法 stat_index 不应改变成长表",
		failures
	)

	# reset 清零
	world.reset(9)
	_expect(
		is_equal_approx(world.get_upgrade_scale(0, SimWorldScript.STAT_DAMAGE), 1.0),
		"reset 后成长表应复位为 1.0",
		failures
	)

	if failures.is_empty():
		print("validate_shop_purchase: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_shop_purchase: %s" % failure)
	printerr("validate_shop_purchase: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
