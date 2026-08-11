extends SceneTree

## 模拟层三角函数的验证。
##
## 两件事，方向相反但都必须成立：
##
##   1. SimMath 的结果与平台内置的 sin/cos/atan2 足够接近。它们只用四则运算，
##      跨平台一定逐位相同，但「一致地算错」仍然是算错——僵尸会朝着一个
##      稳定但错误的方向走。所以要对着内置版本量误差。
##   2. 模拟层可达的源码里不再出现平台三角函数的字面调用。第 1 条只能证明
##      现有实现是对的，挡不住明天有人在 SimWorld 里顺手写一个 cos()。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_sim_math.gd

const SimMathScript = preload("res://scripts/sim/sim_math.gd")

## 允许的最大绝对误差。sin/cos 的截断误差约 6e-12，atan2 约 1e-9；
## 卡在比实测高一个数量级的位置：够松，不会被浮点噪声误报；
## 够紧，换掉多项式阶数会立刻被发现。
const TRIG_TOLERANCE := 1e-10
const ATAN_TOLERANCE := 1e-8

## 模拟层可达、因而不允许出现平台三角函数的文件。
## scripts/sim/ 之外的那几个是被 SimWorld preload 进来的。
const SIM_REACHABLE_FILES := [
	"res://scripts/sim/sim_world.gd",
	"res://scripts/sim/sim_combat.gd",
	"res://scripts/sim/sim_collision.gd",
	"res://scripts/sim/sim_hit_geometry.gd",
	"res://scripts/sim/flow_field.gd",
	"res://scripts/sim/flow_field_grid.gd",
	"res://scripts/sim/deterministic_rng.gd",
	"res://scripts/combat/zombie_behavior_math.gd",
	"res://scripts/combat/explosion_math.gd",
	"res://scripts/combat/hit_response_math.gd",
	"res://scripts/combat/melee_attack_cycle.gd",
]

## 字面名单。sqrt 不在其中：IEEE 754 要求它正确舍入，跨平台本来就一致。
const FORBIDDEN_CALLS := ["sin(", "cos(", "tan(", "atan(", "atan2(", "asin(", "acos(", "pow("]

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	failures.append_array(_check_sine_cosine_accuracy())
	failures.append_array(_check_arc_tangent_accuracy())
	failures.append_array(_check_rotate_matches_builtin())
	failures.append_array(_check_no_platform_trig_on_sim_path())

	if failures.is_empty():
		print("validate_sim_math: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_sim_math: %s" % failure)
	printerr("validate_sim_math: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)

func _check_sine_cosine_accuracy() -> Array[String]:
	var failures: Array[String] = []
	var worst_sine := 0.0
	var worst_cosine := 0.0
	# 扫两整圈再加一段圈外的角度：折叠逻辑的边界（±PI/2、±PI）以及
	# wrap_to_pi 对圈外输入的处理都必须落在容差内。
	for step in range(-1440, 1441):
		var angle := float(step) * 0.0125
		worst_sine = maxf(worst_sine, absf(SimMathScript.sine(angle) - sin(angle)))
		worst_cosine = maxf(worst_cosine, absf(SimMathScript.cosine(angle) - cos(angle)))
	_expect(
		worst_sine <= TRIG_TOLERANCE,
		"sine 与内置 sin 的最大偏差 %s 超过容差 %s" % [worst_sine, TRIG_TOLERANCE],
		failures
	)
	_expect(
		worst_cosine <= TRIG_TOLERANCE,
		"cosine 与内置 cos 的最大偏差 %s 超过容差 %s" % [worst_cosine, TRIG_TOLERANCE],
		failures
	)
	# 恒等式是对多项式实现的独立交叉检查：它不依赖内置实现是否正确。
	var worst_identity := 0.0
	for step in range(0, 720):
		var angle := float(step) * 0.05
		var s: float = SimMathScript.sine(angle)
		var c: float = SimMathScript.cosine(angle)
		worst_identity = maxf(worst_identity, absf(s * s + c * c - 1.0))
	_expect(
		worst_identity <= TRIG_TOLERANCE,
		"sin²+cos²=1 的最大偏差 %s 超过容差" % worst_identity,
		failures
	)
	return failures

func _check_arc_tangent_accuracy() -> Array[String]:
	var failures: Array[String] = []
	var worst := 0.0
	# 覆盖四个象限与两条轴：象限折叠写错时误差是 PI 量级，绝不会被容差放过。
	for y_step in range(-24, 25):
		for x_step in range(-24, 25):
			var y := float(y_step) * 0.37
			var x := float(x_step) * 0.41
			if x == 0.0 and y == 0.0:
				continue
			var difference: float = absf(SimMathScript.arc_tangent2(y, x) - atan2(y, x))
			# atan2 在 ±PI 附近是跨越式的，绕一圈的差不算差。
			if difference > PI:
				difference = absf(difference - TAU)
			worst = maxf(worst, difference)
	_expect(
		worst <= ATAN_TOLERANCE,
		"arc_tangent2 与内置 atan2 的最大偏差 %s 超过容差 %s" % [worst, ATAN_TOLERANCE],
		failures
	)
	_expect(
		SimMathScript.arc_tangent2(0.0, 0.0) == 0.0,
		"arc_tangent2(0, 0) 必须有确定取值，不能落到实现定义的结果上",
		failures
	)
	return failures

func _check_rotate_matches_builtin() -> Array[String]:
	var failures: Array[String] = []
	var worst := 0.0
	for step in range(-360, 361):
		var angle := float(step) * 0.05
		var source := Vector2(0.6, -0.8)
		var rotated: Vector2 = SimMathScript.rotate(source, angle)
		worst = maxf(worst, (rotated - source.rotated(angle)).length())
	_expect(
		worst <= 1e-6,
		"rotate 与内置 Vector2.rotated 的最大偏差 %s 过大" % worst,
		failures
	)
	return failures

## 模拟层可达的源码里不得再出现平台三角函数的字面调用。
func _check_no_platform_trig_on_sim_path() -> Array[String]:
	var failures: Array[String] = []
	for path in SIM_REACHABLE_FILES:
		if not FileAccess.file_exists(path):
			failures.append("清单里的文件不存在：%s（改过目录就要同步这里）" % path)
			continue
		var source := FileAccess.get_file_as_string(path)
		var line_number := 0
		for line in source.split("\n"):
			line_number += 1
			var code := line
			var comment_at := code.find("#")
			if comment_at >= 0:
				code = code.substr(0, comment_at)
			for call_name in FORBIDDEN_CALLS:
				# 前一个字符是标识符的一部分时不算：SimMath.sine( 与
				# direction_from_angle( 里都含有子串，它们正是本来该用的东西。
				var at := code.find(call_name)
				while at >= 0:
					var preceded_by_word := false
					if at > 0:
						var previous := code[at - 1]
						preceded_by_word = (
							previous == "_" or previous == "."
							or (previous >= "a" and previous <= "z")
							or (previous >= "A" and previous <= "Z")
						)
					if not preceded_by_word:
						failures.append(
							"%s:%d 直接调用了平台三角函数 %s，模拟层必须走 SimMath" % [
								path, line_number, call_name
							]
						)
					at = code.find(call_name, at + 1)
	return failures
