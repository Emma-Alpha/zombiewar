extends SceneTree

## 尸群包围行为的回归。
##
## 守的是这个类型最核心的一条体验：**玩家的活动空间要真的被压缩**。
##
## 全员直奔玩家时，流场会把整群僵尸压在同一条最短路径上，它们排成一列到达，
## 玩家只要一直往后退就能持续拉开距离——尸潮再多也只是排队挨打，画面上人很多、
## 手上一点不紧张。这个缺陷不会让任何测试变红，也不影响任何数值，
## 所以只能由行为回归本身守住。
##
## 判据是把僵尸全部从**同一侧**放出来，跑若干 tick 之后看它们有没有铺开成一圈：
## 如果还挤在出发那一侧，说明包围没有生效。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_zombie_surround.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

const GRID_ORIGIN := Vector2(-24.5, -19.5)
const GRID_CELL_SIZE := 1.0
const GRID_WIDTH := 49
const GRID_HEIGHT := 39
const SEED := 20260812

const PLAYER_POSITION := Vector2(0.0, 0.0)
const ZOMBIE_COUNT := 24
const APPROACH_TICKS := 400

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var world: SimWorld = SimWorldScript.new()
	world.configure(GRID_ORIGIN, GRID_CELL_SIZE, GRID_WIDTH, GRID_HEIGHT)
	world.reset(SEED)
	world.configure_zombie_profile(0, 50, 1.3)
	world.set_player_snapshot(0, PLAYER_POSITION, true, true)

	# 全部从玩家左侧放出，排成一堵墙——最容易暴露「排成一列冲过来」的布局。
	for index in range(ZOMBIE_COUNT):
		var row := float(index % 6) - 2.5
		var column := float(index / 6)
		world.spawn_zombie(
			Vector2(-9.0 - column * 1.4, row * 1.2),
			0.0,
			0
		)

	for _tick in range(APPROACH_TICKS):
		world.set_player_snapshot(0, PLAYER_POSITION, true, true)
		world.step_tick()

	_test_zombies_reached_the_player(world)
	_test_zombies_spread_around_the_player(world)
	_report()


func _test_zombies_reached_the_player(world: SimWorld) -> void:
	var arrived := 0
	for index in range(world.get_zombie_count()):
		if world.get_zombie_position(index).distance_to(PLAYER_POSITION) <= 3.0:
			arrived += 1
	_check(
		"most zombies must actually reach the player (%d of %d within 3m)" % [
			arrived, world.get_zombie_count()
		],
		arrived >= int(float(ZOMBIE_COUNT) * 0.6)
	)


## 铺开程度用「有多少僵尸绕到了出发侧的对面」来衡量，而不是用平均角度——
## 平均角度对一堆挤在同一侧的僵尸同样可以很好看。
func _test_zombies_spread_around_the_player(world: SimWorld) -> void:
	var near_side := 0
	var far_side := 0
	var quadrants := {0: 0, 1: 0, 2: 0, 3: 0}
	for index in range(world.get_zombie_count()):
		var offset := world.get_zombie_position(index) - PLAYER_POSITION
		if offset.length() > 6.0:
			continue
		if offset.x < 0.0:
			near_side += 1
		else:
			far_side += 1
		var quadrant := (0 if offset.x >= 0.0 else 2) + (0 if offset.y >= 0.0 else 1)
		quadrants[quadrant] = int(quadrants[quadrant]) + 1

	var surrounding := near_side + far_side
	print("[diag] 近侧 %d / 远侧 %d / 象限 %s" % [near_side, far_side, str(quadrants)])
	_check("zombies must gather around the player", surrounding > 0)
	if surrounding == 0:
		return
	# 全员来自左侧；如果右侧一个都没有，就是排成一列贴上来而不是包围。
	_check(
		"zombies must wrap to the far side, not pile up on the approach side (near %d / far %d)" % [
			near_side, far_side
		],
		far_side >= 1
	)
	var occupied_quadrants := 0
	for quadrant in quadrants.keys():
		if int(quadrants[quadrant]) > 0:
			occupied_quadrants += 1
	_check(
		"the horde must occupy at least 3 of the 4 quadrants around the player (got %d: %s)" % [
			occupied_quadrants, str(quadrants)
		],
		occupied_quadrants >= 3
	)


func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)


func _report() -> void:
	if failures.is_empty():
		print("validate_zombie_surround: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
