extends SceneTree

## 真实战斗模拟自测：驱动 SimWorld 跑两波，量化对比"买商店前后"的成长。
##
## 这不是 UI 自动化（不碰菜单/输入），而是直接驱动确定性模拟层跑真实波次。
## 输出可对比的量化指标，用来对标 Brotato 的成长曲线。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/selftest_combat_growth.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

## demo 地图的波次配置（取自 demo_map.tres 第一波，普通僵尸为主）。
func _demo_waves() -> Array[Dictionary]:
	return [
		{
			"spawn_interval_ticks": 10,
			"entries": [{"profile_index": 0, "count": 12, "spawn_point_index": 0}],
		},
		{
			"spawn_interval_ticks": 8,
			"entries": [{"profile_index": 0, "count": 20, "spawn_point_index": 0}],
		},
	]

func _demo_spawn_points() -> Array[Dictionary]:
	return [{"spawn_id": &"center", "position": Vector2(0.0, -8.0), "radius": 4.0, "spacing": 0.9}]

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 战斗成长自测：对标 Brotato 的复利成长 ===")
	var world := SimWorldScript.new()
	# 必须先 configure 网格，否则 reset 里 flow_field.setup(grid) 用未初始化的
	# 网格（宽高为 0），step_tick 的僵尸更新/流场 BFS 会卡死。
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(20260807)

	# 注册僵尸档案（普通 50 血）+ 武器档案（手枪 35 伤）。
	world.configure_zombie_profile(0, 50, 1.0)
	world.set_default_move_speed(1.30)
	world.set_perception_range(60.0)
	# 死亡规则：普通僵尸 32% 概率触发掉落组，组里有材料掉落（demo_map 的真实配置）。
	# event_type=1 是 DROP_MATERIAL，材料区间 2-10。
	world.configure_zombie_death_groups(0, [
		{
			"group_id": &"common_drop",
			"trigger_chance_per_10000": 6000,
			"events": [
				{"event_type": 1, "weight": 3, "material_drop_min": 8, "material_drop_max": 12},
				{"event_type": 1, "weight": 2, "material_drop_min": 13, "material_drop_max": 18},
			],
		},
	])
	world.configure_weapon_profile(0, 35.0, 24.0, 0.35, 3.0, 0.8, 1.8, 0, 0.0, 1)

	# 玩家在原地（slot 0），活着。
	world.set_player_snapshot(0, Vector2.ZERO, true, true)

	# 配置波次并启动。
	world.configure_wave_schedule(
		_demo_waves(), _demo_spawn_points(), 1, 300, 300  # LOOP, 15s 波间
	)
	world.start_wave_schedule()

	var kills_wave1 := 0
	var material_before := 0
	var damage_before := 0.0

	# ---- 跑第一波：自动瞄准最近僵尸开火 ----
	var ticks := 0
	while ticks < 400 and world.get_zombie_count() >= 0:
		world.step_tick()
		ticks += 1
		# 玩家每 3 tick 开一枪（≈手枪 3 发/秒），瞄准最近的僵尸。
		if ticks % 3 == 0 and world.get_zombie_count() > 0:
			var target_pos := world.get_zombie_position(0)
			var aim := (target_pos - Vector2.ZERO).normalized()
			if aim.length_squared() < 0.5:
				aim = Vector2(0.0, -1.0)
			world.queue_fire_event(0, 0, Vector2.ZERO, 1.0, aim)
		# 累计本波击杀（从死亡事件数）。
		kills_wave1 += world.tick_death_events.size()
		# 波间出现则停
		if not world.tick_wave_events.is_empty():
			for ev in world.tick_wave_events:
				if ev.get("kind", StringName()) == &"intermission_started":
					ticks = 9999  # 跳出
					break

	material_before = world.get_player_material(0)
	damage_before = world.get_upgrade_scale(0, SimWorldScript.STAT_DAMAGE)

	print("第一波击杀: %d" % kills_wave1)
	print("第一波后材料: %d" % material_before)
	print("买商店前伤害倍率: %.2f" % damage_before)

	# ---- 波间商店：买最便宜的回血（10 材料），断言第一波后能买得起 ----
	var failures: Array[String] = []
	if material_before >= 10:
		world.queue_shop_purchase(0, &"heal", -1, 25.0, 10)
		world.step_tick()
		print("买了回血 +25，材料剩: %d" % world.get_player_material(0))
	else:
		failures.append("第一波后材料 %d 买不起最便宜的 10 材料升级——经济数值不对" % material_before)

	# 买伤害升级（如果够 12），验证成长生效
	if world.get_player_material(0) >= 12:
		world.queue_shop_purchase(0, &"stat", SimWorldScript.STAT_DAMAGE, 1.12, 12)
		world.step_tick()
		print("买了伤害 +12%%，材料剩: %d" % world.get_player_material(0))
		if not is_equal_approx(world.get_upgrade_scale(0, SimWorldScript.STAT_DAMAGE), 1.12):
			failures.append("买伤害升级后倍率应为 1.12，实际 %.2f" % world.get_upgrade_scale(0, SimWorldScript.STAT_DAMAGE))

	# ---- 跑第二波：对比伤害成长 ----
	var kills_wave2 := 0
	ticks = 0
	while ticks < 500:
		world.step_tick()
		ticks += 1
		if ticks % 3 == 0 and world.get_zombie_count() > 0:
			var target_pos := world.get_zombie_position(0)
			var aim := (target_pos - Vector2.ZERO).normalized()
			if aim.length_squared() < 0.5:
				aim = Vector2(0.0, -1.0)
			world.queue_fire_event(0, 0, Vector2.ZERO, 1.0, aim)
		kills_wave2 += world.tick_death_events.size()
		if not world.tick_wave_events.is_empty():
			for ev in world.tick_wave_events:
				if ev.get("kind", StringName()) == &"intermission_started":
					ticks = 9999
					break

	print("第二波击杀: %d" % kills_wave2)
	print("最终材料: %d" % world.get_player_material(0))
	print("最终伤害倍率: %.2f" % world.get_upgrade_scale(0, SimWorldScript.STAT_DAMAGE))

	print("=== 自测完成 ===")
	if failures.is_empty():
		print("selftest_combat_growth: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("selftest_combat_growth: %s" % failure)
	printerr("selftest_combat_growth: FAIL (%d)" % failures.size())
	quit(1)
