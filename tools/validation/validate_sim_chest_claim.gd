extends SceneTree

## 补给箱领取的确定性验证。
##
## 存在的理由是一个真实发生过的联机故障：领取原本由 PickupChest 的
## ClaimArea.body_entered 驱动——一个表现层的物理重叠。联机下本机玩家的身体
## 跑在前面、远端玩家的身体是插值追上来的，于是同一个箱子在各端被不同的人、
## 在不同的帧领走。箱子又是阻挡几何，它消失的时刻不同，各端的流场就在不同的
## tick 上重算，僵尸从此分道扬镳，最终表现为「两边刷出来的道具不一样、
## 存活数也不一样」。
##
## 现在领取住在 SimWorld._resolve_chest_claims() 里，判定只读量化后的玩家
## 坐标。这个脚本守住三条：领取在确定的 tick 发生、平局有确定的赢家、
## 同一串输入喂给两个世界得到逐位相同的哈希。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_sim_chest_claim.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const SimHasherScript = preload("res://scripts/sim/sim_hasher.gd")

const ROOM_SEED := 20260810
const GRID_ORIGIN := Vector2(-24.5, -19.5)
const GRID_CELL_SIZE := 1.0
const GRID_WIDTH := 49
const GRID_HEIGHT := 39
const TICK_COUNT := 240

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	failures.append_array(_check_claim_requires_range())
	failures.append_array(_check_tie_break_is_lowest_slot())
	failures.append_array(_check_dead_and_absent_players_cannot_claim())
	failures.append_array(_check_claim_is_once_only())
	failures.append_array(_check_presentation_cannot_move_chest_state())
	failures.append_array(_check_replay_determinism())

	if failures.is_empty():
		print("validate_sim_chest_claim: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_sim_chest_claim: %s" % failure)
	quit(1)

func _make_world():
	var world = SimWorldScript.new()
	world.configure(GRID_ORIGIN, GRID_CELL_SIZE, GRID_WIDTH, GRID_HEIGHT)
	world.configure_inventory_profiles(
		[{"category": 2, "max_stack": 999, "weapon_id": &"", "mod_id": -1}],
		PackedInt32Array([0, 0, 0, 0])
	)
	world.reset(ROOM_SEED)
	return world

func _spawn_one_shot_chest(world, position: Vector2) -> int:
	return world.spawn_chest(
		position,
		0,
		1,
		-1,
		position - SimWorldScript.CHEST_BLOCKER_HALF_SIZE,
		position + SimWorldScript.CHEST_BLOCKER_HALF_SIZE,
		SimWorldScript.CHEST_CLAIM_RADIUS
	)

func _claims(world) -> Array:
	var result: Array = []
	for event in world.tick_chest_events:
		if event["kind"] == &"chest_claimed":
			result.append(event)
	return result

## 够不着不算领取，够得着才算。边界取 claim_radius + PLAYER_RADIUS，
## 与基线 ClaimArea 和玩家胶囊重叠的那一刻对齐。
func _check_claim_requires_range() -> Array[String]:
	var failures: Array[String] = []
	var world = _make_world()
	var chest := _spawn_one_shot_chest(world, Vector2(5.0, 0.0))
	var reach: float = SimWorldScript.CHEST_CLAIM_RADIUS + SimWorldScript.PLAYER_RADIUS

	world.set_player_snapshot(0, Vector2(5.0 + reach + 0.05, 0.0), true, true)
	world.step_tick()
	if not _claims(world).is_empty():
		failures.append("玩家在领取范围外却拿到了箱子")

	world.set_player_snapshot(0, Vector2(5.0 + reach - 0.05, 0.0), true, true)
	world.step_tick()
	var claims := _claims(world)
	if claims.size() != 1:
		failures.append("玩家进入领取范围后未产生恰好一次领取（%d 次）" % claims.size())
	elif int(claims[0]["chest_id"]) != chest or int(claims[0]["slot"]) != 0:
		failures.append("领取事件的 chest_id/slot 不正确")
	return failures

## 两人同时踩上同一个箱子：赢家必须是确定的，而且是槽位小的那个。
## 换成「比距离」会把结果交给浮点比较，那恰恰是各端最容易算出不同答案的东西。
func _check_tie_break_is_lowest_slot() -> Array[String]:
	var failures: Array[String] = []
	for attempt in range(2):
		var world = _make_world()
		_spawn_one_shot_chest(world, Vector2.ZERO)
		# 两个玩家到箱子的距离完全相同，只是方向相反。
		world.set_player_snapshot(2, Vector2(0.5, 0.0), true, true)
		world.set_player_snapshot(1, Vector2(-0.5, 0.0), true, true)
		world.step_tick()
		var claims := _claims(world)
		if claims.size() != 1:
			failures.append("同距离平局产生了 %d 次领取，应恰好 1 次" % claims.size())
			continue
		if int(claims[0]["slot"]) != 1:
			failures.append(
				"平局赢家应是槽位小的一方（1），实际是 %d" % int(claims[0]["slot"])
			)
		if not failures.is_empty():
			break
		if attempt == 1 and failures.is_empty():
			pass
	return failures

func _check_dead_and_absent_players_cannot_claim() -> Array[String]:
	var failures: Array[String] = []
	var world = _make_world()
	_spawn_one_shot_chest(world, Vector2.ZERO)
	# 倒地的玩家站在箱子上
	world.set_player_snapshot(0, Vector2(0.0, 0.0), false, true)
	world.step_tick()
	if not _claims(world).is_empty():
		failures.append("倒地的玩家不应该能领取补给")
	# 离席的座位（掉线）同样不行
	world.set_player_snapshot(0, Vector2(0.0, 0.0), true, false)
	world.step_tick()
	if not _claims(world).is_empty():
		failures.append("不在场的座位不应该能领取补给")
	# 活着且在场就应该拿到
	world.set_player_snapshot(0, Vector2(0.0, 0.0), true, true)
	world.step_tick()
	if _claims(world).size() != 1:
		failures.append("活着且在场的玩家应当领取到补给")
	return failures

## 领取只发生一次：玩家站着不走，后续 tick 不能反复触发。
func _check_claim_is_once_only() -> Array[String]:
	var failures: Array[String] = []
	var world = _make_world()
	_spawn_one_shot_chest(world, Vector2.ZERO)
	world.set_player_snapshot(0, Vector2(0.0, 0.0), true, true)
	var total := 0
	for _tick in range(10):
		world.step_tick()
		total += _claims(world).size()
	if total != 1:
		failures.append("站在箱子上 10 个 tick 触发了 %d 次领取，应恰好 1 次" % total)
	return failures

## 表现层不得改动箱子状态。
##
## 这条断言是一次真实回归换来的：曾经有个 release_chest()，让兑现失败
## （弹药已满）的箱子回到地上。兑现成败读的是玩家当前弹药与存活，而这两个量
## 在各端差着一个 RTT——开火的人自己那端立刻扣弹，别人那端要等帧。于是同一个
## 箱子一端消耗、一端留下，chest_state 分叉，箱子又是阻挡几何，流场跟着分叉，
## 最终表现为「他捡走了我这边还看得见」与「两边血量对不上」。
##
## 所以这里守的不是某个函数的行为，而是一条边界：模拟层的箱子状态只能由
## 模拟层自己写。任何让表现层把 CONSUMED 改回 ACTIVE 的入口都必须让这条失败。
func _check_presentation_cannot_move_chest_state() -> Array[String]:
	var failures: Array[String] = []
	var world = _make_world()
	if world.has_method("release_chest"):
		failures.append(
			"SimWorld 又出现了 release_chest()：表现层一旦能把箱子放回地上，" +
			"各端就会因为弹药状态不同步而分叉（见本函数上方说明）"
		)
	var chest := _spawn_one_shot_chest(world, Vector2.ZERO)
	world.set_player_snapshot(0, Vector2(0.0, 0.0), true, true)
	world.step_tick()
	var index := world.index_of_chest(chest)
	if world.get_chest_state(index) != SimWorldScript.CHEST_STATE_CONSUMED:
		failures.append("一次性箱子被领取后状态应为 CONSUMED")
	# 领取后玩家继续站在原地：状态必须一直是 CONSUMED，不能被任何路径翻回去。
	for _tick in range(20):
		world.step_tick()
		if world.get_chest_state(index) != SimWorldScript.CHEST_STATE_CONSUMED:
			failures.append("已领取的箱子在后续 tick 被改回了可领取状态")
			break
	return failures

## 同一串玩家轨迹喂给两个独立的世界，逐 tick 哈希必须始终相等，
## 且领取必须落在同一个 tick 上。
func _check_replay_determinism() -> Array[String]:
	var failures: Array[String] = []
	var first := _replay()
	var second := _replay()
	if first["hashes"] != second["hashes"]:
		for index in range(mini(first["hashes"].size(), second["hashes"].size())):
			if first["hashes"][index] != second["hashes"][index]:
				failures.append("第 %d tick 哈希分叉" % index)
				break
	if first["claim_ticks"] != second["claim_ticks"]:
		failures.append(
			"两次回放的领取 tick 不同：%s vs %s" % [first["claim_ticks"], second["claim_ticks"]]
		)
	if first["claim_ticks"].is_empty():
		failures.append("回放中没有发生任何领取，这个用例没有测到东西")
	return failures

func _replay() -> Dictionary:
	var world = _make_world()
	for index in range(4):
		_spawn_one_shot_chest(world, Vector2(-6.0 + float(index) * 4.0, 2.0))
	var hashes: Array = []
	var claim_ticks: Array = []
	for tick in range(TICK_COUNT):
		# 两个玩家沿相反方向横穿整排箱子
		var sweep := -10.0 + float(tick) * 0.12
		world.set_player_snapshot(0, Vector2(sweep, 2.0), true, true)
		world.set_player_snapshot(1, Vector2(-sweep, 2.0), true, true)
		world.step_tick()
		for event in world.tick_chest_events:
			claim_ticks.append([tick, int(event["chest_id"]), int(event["slot"])])
		hashes.append(SimHasherScript.hash_world(world))
	return {"hashes": hashes, "claim_ticks": claim_ticks}
