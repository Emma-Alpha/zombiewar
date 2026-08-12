extends SceneTree

## 模拟层的 CPU 性能基线。
##
## 这不是 validate_*：它不判定通过与否，只**测量并打印数字**。性能工作的第一条
## 纪律是先测量再优化，而这个项目此前没有任何耗时基线——validate_combat_frame_stability
## 测的是行为正确性（帧率无关的射击间隔、池复用），一次也没有测过实际耗时。
##
## 只测 CPU 侧的模拟层，因为它 headless 可测且跨平台可比。渲染（draw call、GPU 时间、
## 蒙皮动画）必须在真机带窗口跑，见报告里给出的 Performance monitor 方法。
##
## 预算参考：模拟按 20Hz 推进（SimClock.TICK_SECONDS = 0.05），而渲染要跑 60fps
## （每帧 16.67ms）。一个 tick 会整个落在某一帧里，所以单 tick 的耗时必须远小于
## 16.67ms，否则每逢推进 tick 的那一帧就会掉帧。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/benchmark_simulation.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const DEMO_MAP_PATH := "res://resources/maps/demo/demo_map.tres"

const GRID_ORIGIN := Vector2(-24.5, -19.5)
const GRID_CELL_SIZE := 1.0
const GRID_WIDTH := 49
const GRID_HEIGHT := 39
const SEED := 20260812

const ZOMBIE_COUNTS: Array[int] = [50, 150, 300]
const WARMUP_TICKS := 20
const MEASURED_TICKS := 120


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	print("=== 模拟层 CPU 基线 (headless, 单 tick 耗时) ===")
	print("预算参考: 60fps 单帧 16.67ms；tick 必须远小于它")
	for count in ZOMBIE_COUNTS:
		_benchmark_tick(count)
	print("")
	_benchmark_flow_field_rebuild()
	print("")
	_report_grid_scale()
	quit(0)


func _make_world() -> SimWorld:
	var world: SimWorld = SimWorldScript.new()
	world.configure(GRID_ORIGIN, GRID_CELL_SIZE, GRID_WIDTH, GRID_HEIGHT)
	world.reset(SEED)
	# 一个普通僵尸档案就够测吞吐：耗时来自数量与寻路，不来自档案数值。
	world.configure_zombie_profile(0, 50, 1.3)
	return world


func _populate(world: SimWorld, count: int) -> void:
	# 均匀撒在网格内，避免全部叠在一个格子上而低估碰撞与分离的开销。
	var columns := int(sqrt(float(count))) + 1
	for index in range(count):
		var column := index % columns
		var row := index / columns
		var position := Vector2(
			GRID_ORIGIN.x + 2.0 + float(column) * 1.6,
			GRID_ORIGIN.y + 2.0 + float(row) * 1.6
		)
		world.spawn_zombie(position, 0.0, 0)


func _benchmark_tick(count: int) -> void:
	var world := _make_world()
	world.set_player_snapshot(0, Vector2(0.0, 6.0), true, true)
	_populate(world, count)
	for _index in range(WARMUP_TICKS):
		world.step_tick()

	var samples: Array[float] = []
	var total := 0.0
	var worst := 0.0
	for _index in range(MEASURED_TICKS):
		var started := Time.get_ticks_usec()
		world.step_tick()
		var elapsed := float(Time.get_ticks_usec() - started) / 1000.0
		samples.append(elapsed)
		total += elapsed
		worst = maxf(worst, elapsed)
	samples.sort()
	var average := total / float(MEASURED_TICKS)
	var p95 := samples[int(float(MEASURED_TICKS) * 0.95)]
	print("%4d 只僵尸: 平均 %6.3f ms | p95 %6.3f ms | 最坏 %6.3f ms | 占 60fps 单帧 %5.1f%%" % [
		count, average, p95, worst, worst / 16.67 * 100.0
	])


## 流场是玩家每跨一个格子边界就**同步**重建一次的多源 BFS。
## 玩家以约 5 m/s 移动、格子边长 1 米，意味着移动中大约每 0.2 秒就要重建一次，
## 而重建落在触发它的那一帧里。这是这套导航最值得盯住的单点开销。
func _benchmark_flow_field_rebuild() -> void:
	print("=== 流场重建 (玩家每跨一格触发一次，同步执行) ===")
	var world := _make_world()
	_populate(world, 300)
	world.set_player_snapshot(0, Vector2(0.0, 6.0), true, true)
	world.step_tick()

	# 单次重建的裸成本：强制置脏，绕过节流。
	var total := 0.0
	var worst := 0.0
	var rebuilds := 60
	for index in range(rebuilds):
		var offset := float(index % 20) - 10.0
		world.set_player_snapshot(0, Vector2(offset, 6.0), true, true)
		world.grid.mark_dirty()
		var started := Time.get_ticks_usec()
		world.step_tick()
		var elapsed := float(Time.get_ticks_usec() - started) / 1000.0
		total += elapsed
		worst = maxf(worst, elapsed)
	print("单次重建 tick: 平均 %6.3f ms | 最坏 %6.3f ms | 占 60fps 单帧 %5.1f%%" % [
		total / float(rebuilds), worst, worst / 16.67 * 100.0
	])

	_benchmark_moving_players(1)
	_benchmark_moving_players(4)


## 真实负载：玩家以 5 m/s 持续移动，不人为置脏，让节流按实际条件生效。
## 这才是「跑动中会不会掉帧」对应的场景。
func _benchmark_moving_players(player_count: int) -> void:
	var world := _make_world()
	_populate(world, 300)
	var ticks := 200
	var tick_seconds := 0.05
	var speed := 5.0
	for slot in range(player_count):
		world.set_player_snapshot(slot, Vector2(float(slot) * 1.5, 6.0), true, true)
	world.step_tick()
	var rebuilds_before: int = world.flow_field.get_rebuild_count()

	var total := 0.0
	var worst := 0.0
	for index in range(ticks):
		# 每个玩家沿不同方向走，模拟四人分散推进——任一玩家跨格都会触发重建。
		for slot in range(player_count):
			var travelled := float(index) * speed * tick_seconds
			var lane := float(slot) * 1.5
			var position := (
				Vector2(fmod(travelled, 18.0) - 9.0, 6.0 + lane)
				if slot % 2 == 0
				else Vector2(6.0 + lane, fmod(travelled, 18.0) - 9.0)
			)
			world.set_player_snapshot(slot, position, true, true)
		var started := Time.get_ticks_usec()
		world.step_tick()
		var elapsed := float(Time.get_ticks_usec() - started) / 1000.0
		total += elapsed
		worst = maxf(worst, elapsed)
	var rebuilds: int = world.flow_field.get_rebuild_count() - rebuilds_before
	var seconds := float(ticks) * tick_seconds
	print("%d 人持续移动 (300 僵尸): 平均 %6.3f ms | 最坏 %6.3f ms | 重建 %d 次 / %.0f 秒 = %.1f 次/秒" % [
		player_count, total / float(ticks), worst, rebuilds, seconds, float(rebuilds) / seconds
	])


func _report_grid_scale() -> void:
	var cells := GRID_WIDTH * GRID_HEIGHT
	print("=== 规模 ===")
	print("流场网格: %d x %d = %d 格（每次重建是一次覆盖全格的多源 BFS）" % [
		GRID_WIDTH, GRID_HEIGHT, cells
	])
	print("同屏僵尸上限: 300（demo_map.maximum_active_zombies）")
	print("近景骨骼动画上限: 48（ZombieRenderer.NEAR_LOD_COUNT），其余走 MultiMesh 静态姿势")
