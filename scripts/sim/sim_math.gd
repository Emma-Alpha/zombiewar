extends RefCounted
class_name SimMath

## 模拟层的确定性三角函数。
##
## GDScript 的 sin/cos/atan2 直接落到平台的 libm，而 IEEE 754 **不**要求超越
## 函数正确舍入——同一个输入在 x86 的 glibc、ARM 的 Bionic 和 Web 导出的 wasm
## 里允许在最后一位上不同。模拟层要的是逐位一致，一位之差经过几百 tick 的
## 放大就是「僵尸在你那边咬到了、在我这边没有」。
##
## 四则运算与 sqrt 不在此列：标准要求它们正确舍入，跨平台本来就逐位相同。
## 所以 length()、normalized()、distance_to() 这些保持原样，不必替换。
##
## 这里只用 +、-、*、/、比较和 floor，因此在任何平台上都是同一串位。代价是
## 精度：sin/cos 截断误差约 6e-12，atan2 约 1e-9。对「僵尸朝哪个方向」和
## 「子弹散布多少」而言这远在可见性以下，而一致性是不可让的那一头。
##
## 覆盖率与精度由 tools/validation/validate_sim_math.gd 守着。

const HALF_PI := PI / 2.0

## atan 的自变量折叠用，见 _arc_tangent_unit()。
## TAN_15 是 tan(PI/12) = 2 - √3，折叠的阈值；TAN_30 与 PI_OVER_6 是折叠本身。
const TAN_15 := 0.2679491924311227
const TAN_30 := 0.5773502691896257
const PI_OVER_6 := 0.5235987755982988

## 把角度折进 [-PI, PI)。用 floor 而不是 fmod：floor 是精确的，
## 而取模在不同实现上对负数的取整方向并不统一。
static func wrap_to_pi(angle: float) -> float:
	return angle - floor((angle + PI) / TAU) * TAU

static func sine(angle: float) -> float:
	var reduced := wrap_to_pi(angle)
	# sin 关于 ±PI/2 对称，折进 [-PI/2, PI/2] 让多项式的自变量足够小。
	if reduced > HALF_PI:
		reduced = PI - reduced
	elif reduced < -HALF_PI:
		reduced = -PI - reduced
	# 泰勒级数取到 x^15，|x| <= PI/2 时截断误差约 6e-12。写成 Horner 形式：
	# 乘加次数更少，也不必在源码里摊开 15! 这样的大常数。
	var square := reduced * reduced
	var series := -1.0 / 1307674368000.0
	series = 1.0 / 6227020800.0 + square * series
	series = -1.0 / 39916800.0 + square * series
	series = 1.0 / 362880.0 + square * series
	series = -1.0 / 5040.0 + square * series
	series = 1.0 / 120.0 + square * series
	series = -1.0 / 6.0 + square * series
	series = 1.0 + square * series
	return reduced * series

## cos 走 sin 的同一段代码而不是自己一份多项式：两份实现就是两处可以各自
## 写错、并且只在某些角度上互相矛盾的地方。
static func cosine(angle: float) -> float:
	return sine(angle + HALF_PI)

## z ∈ [0, 1] 上的 atan，返回 [0, PI/4]。
static func _arc_tangent_unit(z: float) -> float:
	# 用 atan(z) = PI/6 + atan((z - tan30) / (1 + tan30 * z)) 把自变量压小。
	#
	# 阈值是 tan(PI/12) 而不是 tan(PI/6)：折叠只在阈值以上发生，所以阈值同时
	# 也是**不折叠**那一支的自变量上界。取 tan(PI/6) 会让 z ∈ [0, 0.577] 原样
	# 进级数，而级数在 0.577 处的截断误差是 6e-5——比折叠过的那一支差四个
	# 数量级。取 tan(PI/12) 后两支的残差都落在 ±0.268 以内。
	var offset := 0.0
	var value := z
	if value > TAN_15:
		value = (value - TAN_30) / (1.0 + TAN_30 * value)
		offset = PI_OVER_6
	# 取到 z^11，|z| <= 0.268 时截断误差约 3e-9。
	var square := value * value
	var series := -1.0 / 11.0
	series = 1.0 / 9.0 + square * series
	series = -1.0 / 7.0 + square * series
	series = 1.0 / 5.0 + square * series
	series = -1.0 / 3.0 + square * series
	series = 1.0 + square * series
	return offset + value * series

## 与 atan2(y, x) 同义：返回 (-PI, PI]，象限由两个分量的符号决定。
static func arc_tangent2(y: float, x: float) -> float:
	if x == 0.0 and y == 0.0:
		return 0.0
	var abs_x := absf(x)
	var abs_y := absf(y)
	# 先折进第一个八分区（比值不超过 1），再靠符号把结果转回去。
	var angle := (
		_arc_tangent_unit(abs_y / abs_x) if abs_x >= abs_y
		else HALF_PI - _arc_tangent_unit(abs_x / abs_y)
	)
	if x < 0.0:
		angle = PI - angle
	if y < 0.0:
		angle = -angle
	return angle

## 与 Vector2.rotated() 同义。内置版本用的是平台 libm 的 sin/cos。
static func rotate(vector: Vector2, angle: float) -> Vector2:
	var cosine_value := cosine(angle)
	var sine_value := sine(angle)
	return Vector2(
		vector.x * cosine_value - vector.y * sine_value,
		vector.x * sine_value + vector.y * cosine_value
	)

## 单位圆上的方向向量。等价于 Vector2(cos(angle), sin(angle))。
static func direction_from_angle(angle: float) -> Vector2:
	return Vector2(cosine(angle), sine(angle))
