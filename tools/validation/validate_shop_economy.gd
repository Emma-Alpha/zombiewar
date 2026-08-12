extends SceneTree

## 验证逐玩家材料系统：加/扣/退款/非法 slot/边界。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_shop_economy.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var world := SimWorldScript.new()
	world.reset(7)

	# 初始为 0
	_expect(world.get_player_material(0) == 0, "初始材料应为 0", failures)

	# 加材料
	world.add_player_material(0, 50)
	_expect(world.get_player_material(0) == 50, "加 50 后应为 50", failures)

	# 扣费成功
	_expect(world.spend_player_material(0, 30), "扣 30 应成功", failures)
	_expect(world.get_player_material(0) == 20, "扣 30 后应为 20", failures)

	# 扣费不足失败，不扣
	_expect(not world.spend_player_material(0, 100), "扣 100（不足）应失败", failures)
	_expect(world.get_player_material(0) == 20, "扣费失败后仍应为 20", failures)

	# 非法 slot 拒绝
	world.add_player_material(99, 10)
	_expect(world.get_player_material(99) == 0, "非法 slot 加材料应被忽略", failures)
	_expect(not world.spend_player_material(99, 1), "非法 slot 扣费应失败", failures)

	# 退款（add 负数）钳到非负
	world.add_player_material(0, -50)
	_expect(world.get_player_material(0) == 0, "退款到 0 以下应钳为 0", failures)

	# reset 清零
	world.add_player_material(0, 10)
	world.reset(7)
	_expect(world.get_player_material(0) == 0, "reset 后材料应清零", failures)

	if failures.is_empty():
		print("validate_shop_economy: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_shop_economy: %s" % failure)
	printerr("validate_shop_economy: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
