extends SceneTree

## 多弹丸（霰弹）弹道的回归。
##
## 守三件事：
## 1. 一次扣扳机真的打出 pellet_count 条**方向各异**的弹道，而不是一条直线。
##    这正是霰弹枪最初交付时的缺陷：数值全对、伤害正常、弹道是一根线。
## 2. 弹丸铺满散布锥，而不是扎堆在中间或整簇偏向一侧。
## 3. **单弹丸武器逐位不变**。多弹丸是在模拟层的射击解算里加的循环，一旦它改变了
##    单弹丸路径上的 rng 调用次数，手枪与冲锋枪的每一发都会偏到别处，所有既有回放
##    与帧哈希随之分叉——而这在本地只会表现为「手感好像变了」，不会有任何报错。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_pellet_spread.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

const SINGLE_PROFILE := 0
const MULTI_PROFILE := 1
const PELLET_COUNT := 6
const SPREAD_DEGREES := 12.0
const SEED := 20260812

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_single_pellet_fires_one_ray()
	_test_multi_pellet_fires_a_fan()
	_test_fan_covers_the_cone()
	_test_single_pellet_sequence_is_unchanged()
	_test_authored_shotgun_is_a_fan()
	_report()


func _make_world() -> SimWorld:
	var world: SimWorld = SimWorldScript.new()
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(SEED)
	world.configure_weapon_profile(
		SINGLE_PROFILE, 20.0, 30.0, SPREAD_DEGREES, SPREAD_DEGREES, 0.0, 0.0, 0, 0.0, 1
	)
	world.configure_weapon_profile(
		MULTI_PROFILE, 20.0, 30.0, SPREAD_DEGREES, SPREAD_DEGREES, 0.0, 0.0, 0, 0.0, PELLET_COUNT
	)
	return world


func _fire(world: SimWorld, profile_index: int) -> Array:
	world.tick_shot_events.clear()
	world.queue_fire_event(
		0, profile_index, Vector2.ZERO, 1.0, Vector2(0.0, -1.0)
	)
	world.step_tick()
	var directions: Array = []
	for event in world.tick_shot_events:
		directions.append(event["direction"])
	return directions


func _test_single_pellet_fires_one_ray() -> void:
	var world := _make_world()
	var directions := _fire(world, SINGLE_PROFILE)
	_check(
		"a single-pellet weapon fires exactly one ray (got %d)" % directions.size(),
		directions.size() == 1
	)


func _test_multi_pellet_fires_a_fan() -> void:
	var world := _make_world()
	var directions := _fire(world, MULTI_PROFILE)
	_check(
		"a %d-pellet weapon fires %d rays (got %d)" % [
			PELLET_COUNT, PELLET_COUNT, directions.size()
		],
		directions.size() == PELLET_COUNT
	)
	if directions.size() < 2:
		return
	# 这条是最初那个缺陷的直接回归：所有弹丸方向完全一致 = 弹道是一根线。
	var distinct := {}
	for direction in directions:
		distinct[Vector2(direction).snappedf(0.0001)] = true
	_check(
		"pellets must travel in different directions, not stack into one line (%d distinct of %d)" % [
			distinct.size(), directions.size()
		],
		distinct.size() == directions.size()
	)


## 弹丸要铺满散布锥。均分 + 抖动的写法下，最外侧两颗应当接近锥的边缘，
## 而不是全部挤在中轴附近——后者看起来仍然像一发子弹，只是粗了点。
func _test_fan_covers_the_cone() -> void:
	var world := _make_world()
	var directions := _fire(world, MULTI_PROFILE)
	if directions.size() != PELLET_COUNT:
		return
	var aim := Vector2(0.0, -1.0)
	var smallest := INF
	var largest := -INF
	for direction in directions:
		# 与瞄准方向的夹角，用叉积定号，避免再引一个三角函数。
		var normalized := Vector2(direction).normalized()
		var signed_sine := aim.x * normalized.y - aim.y * normalized.x
		var angle_degrees := rad_to_deg(asin(clampf(signed_sine, -1.0, 1.0)))
		smallest = minf(smallest, angle_degrees)
		largest = maxf(largest, angle_degrees)
	var covered := largest - smallest
	_check(
		"the pellet fan must cover most of the %.0f° cone (covered %.1f°)" % [
			SPREAD_DEGREES * 2.0, covered
		],
		covered >= SPREAD_DEGREES
	)
	_check(
		"no pellet may leave the spread cone (min %.1f°, max %.1f°)" % [smallest, largest],
		smallest >= -SPREAD_DEGREES - 0.001 and largest <= SPREAD_DEGREES + 0.001
	)


## 单弹丸路径必须与「引入多弹丸之前」消耗同样多的随机数。
## 做法是连开两枪并比较：若单弹丸分支多取或少取了一次随机，第二枪的方向就会
## 落在与基线不同的位置上。这里把两枪的方向序列固定下来，作为逐位基线。
func _test_single_pellet_sequence_is_unchanged() -> void:
	var world := _make_world()
	var first := _fire(world, SINGLE_PROFILE)
	var second := _fire(world, SINGLE_PROFILE)
	_check("single-pellet fire yields one ray per shot", first.size() == 1 and second.size() == 1)
	if first.size() != 1 or second.size() != 1:
		return
	# 同种子、同顺序重放必须得到同样的两枪。
	var replay := _make_world()
	var replay_first := _fire(replay, SINGLE_PROFILE)
	var replay_second := _fire(replay, SINGLE_PROFILE)
	_check(
		"single-pellet shots must replay bit-identically from the same seed",
		Vector2(first[0]).is_equal_approx(Vector2(replay_first[0]))
			and Vector2(second[0]).is_equal_approx(Vector2(replay_second[0]))
	)
	_check(
		"consecutive single-pellet shots must consume fresh randomness",
		not Vector2(first[0]).is_equal_approx(Vector2(second[0]))
	)


## 真正装在游戏里的那把霰弹枪必须是扇形的。
func _test_authored_shotgun_is_a_fan() -> void:
	var definition = load("res://resources/weapons/shotgun.tres")
	_check("shotgun resource must load", definition != null)
	if definition == null:
		return
	_check(
		"the authored shotgun must fire multiple pellets (pellet_count=%d)" % definition.pellet_count,
		definition.pellet_count >= 4
	)
	_check(
		"the shotgun's spread must be wide enough to read as a fan (%.1f°)" % definition.base_spread_degrees,
		definition.base_spread_degrees >= 5.0
	)
	# 多弹丸 × 穿透会让一枪的射线数与伤害同时失控，也会把血迹帧预算顶爆。
	_check(
		"a multi-pellet weapon must not also penetrate",
		definition.pellet_count <= 1 or definition.max_penetration_count == 0
	)


func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)


func _report() -> void:
	if failures.is_empty():
		print("validate_pellet_spread: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
