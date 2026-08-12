extends Label3D
class_name DamagePopup

## 伤害数字飘字。命中瞬间生成，向上飘 + 淡出，纯表现、不进模拟。
##
## 数字来自模拟层的 tick_hit_events（已确定），颜色按伤害档位分：
## 低伤害白、高伤害琥珀、击杀红。不处理伤害本身，只读它的数值显示。

## 飘升距离（世界单位）
const RISE_DISTANCE := 1.2
## 存活总时长（秒）
const LIFE_SECONDS := 0.6
## 伤害档位阈值：>= 这个值算「高伤」用琥珀色
const HIGH_DAMAGE_THRESHOLD := 30.0

var _life_remaining := 0.0
var _rise_speed := 0.0
var _start_color := Color.WHITE

func setup(damage: float, world_position: Vector3, killed: bool) -> void:
	global_position = world_position + Vector3(0.0, 1.2, 0.0)
	text = str(roundi(damage))
	_life_remaining = LIFE_SECONDS
	_rise_speed = RISE_DISTANCE / LIFE_SECONDS
	# 伤害越大数字越大；击杀最醒目。
	if killed:
		font_size = 48
		_start_color = Color(0.96, 0.28, 0.28, 1.0)  # 击杀红
	elif damage >= HIGH_DAMAGE_THRESHOLD:
		font_size = 40
		_start_color = Color(0.95, 0.66, 0.0, 1.0)  # 琥珀
	else:
		font_size = 32
		_start_color = Color(0.93, 0.95, 0.92, 1.0)  # 白
	modulate = _start_color

func _process(delta: float) -> void:
	if _life_remaining <= 0.0:
		return
	_life_remaining = maxf(_life_remaining - delta, 0.0)
	global_position.y += _rise_speed * delta
	# 线性淡出：剩余时间比例做 alpha。
	var t := _life_remaining / LIFE_SECONDS
	modulate = Color(_start_color.r, _start_color.g, _start_color.b, t)
	if _life_remaining <= 0.0:
		queue_free()
