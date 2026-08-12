extends SceneTree

## 验证本命武器逐玩家缩放表：set/get 往返、未登记返回 1.0、非法下标被拒绝。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_signature_weapon_scale.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var world := SimWorldScript.new()
	world.reset(12345)

	# 注册 3 个武器档案，模拟 arena 的 configure 流程。
	world.configure_weapon_profile(0, 35.0, 24.0, 0.35, 3.0, 0.8, 1.8, 0, 0.0, 1)
	world.configure_weapon_profile(1, 14.0, 22.0, 1.2, 7.0, 0.5, 5.0, 0, 0.0, 1)
	world.configure_weapon_profile(2, 16.0, 12.0, 9.0, 13.0, 2.0, 6.0, 0, 0.0, 6)
	var count := world.weapon_profile_count()
	_expect(count == 3, "weapon_profile_count 应为 3，实际 %d" % count, failures)

	# 未登记时返回 1.0（无加成）。
	_expect(
		is_equal_approx(world.get_player_signature_scale(0, 0), 1.0),
		"未登记时 slot0/profile0 应为 1.0",
		failures
	)

	# 登记 slot0 的 profile1 为 1.25。
	world.set_player_signature_scale(0, 1, 1.25)
	_expect(
		is_equal_approx(world.get_player_signature_scale(0, 1), 1.25),
		"slot0/profile1 应为 1.25",
		failures
	)
	# 其他槽位/档案不受影响。
	_expect(
		is_equal_approx(world.get_player_signature_scale(0, 0), 1.0),
		"slot0/profile0 应仍为 1.0",
		failures
	)
	_expect(
		is_equal_approx(world.get_player_signature_scale(1, 1), 1.0),
		"slot1/profile1 应仍为 1.0",
		failures
	)

	# 非法下标被拒绝（不崩、不改表）。
	world.set_player_signature_scale(99, 0, 2.0)
	world.set_player_signature_scale(0, 99, 2.0)
	_expect(
		is_equal_approx(world.get_player_signature_scale(0, 1), 1.25),
		"非法下标登记后 slot0/profile1 应仍为 1.25",
		failures
	)

	# reset 后复位为 1.0（尺寸保留）。
	world.reset(12345)
	_expect(
		is_equal_approx(world.get_player_signature_scale(0, 1), 1.0),
		"reset 后 slot0/profile1 应复位为 1.0",
		failures
	)

	if failures.is_empty():
		print("validate_signature_weapon_scale: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_signature_weapon_scale: %s" % failure)
	printerr("validate_signature_weapon_scale: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
