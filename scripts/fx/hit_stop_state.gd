extends RefCounted
class_name HitStopState

## 表现层顿帧（hit-stop）的纯状态机：不持有 Node、不读墙钟以外的东西，
## 只回答「现在该不该冻结画面」。
##
## 刻意**不**用 Engine.time_scale 实现。本项目的模拟层按 tick 推进并跨端共享，
## 缩放引擎时间会连同 SimClock 一起缩放；而各客户端击杀落在各自的渲染帧上，
## 顿帧的起止时刻天然不同，于是每一端都会用不同的速度推进模拟——那是 desync
## 的定义，不是手感。同理，顿帧也绝不能冻结玩家：玩家坐标是模拟层的**输入**
## （见 AGENTS.md「Player position is an input」），冻住本机玩家就等于给各端
## 喂了不同的位置。因此冻结范围只有僵尸表现与镜头，玩家照常移动射击。
##
## 触发策略是「只在击杀与爆炸时顿」，而不是每发子弹都顿：冲锋枪 10 发/秒时
## 逐发顿帧会让画面近乎一半时间静止，顿帧从打击感变成卡顿。

## 击杀一只僵尸的顿帧时长。约合 60fps 下的 3~4 帧。
const KILL_SECONDS := 0.06
## 爆炸的顿帧时长。爆炸是一次清场级事件，值得比单次击杀更重。
const EXPLOSION_SECONDS := 0.1
## 一次顿帧结束后的静默期，防止尸潮里连续击杀把画面顿成幻灯片。
const COOLDOWN_SECONDS := 0.28

var remaining := 0.0
var cooldown_remaining := 0.0

## 请求一次顿帧。返回是否真的触发。
##
## 同时到来的多次请求取**较长**的一个而不是累加：一 tick 打死一片僵尸时
## 累加会直接冻死画面。`ignore_cooldown` 留给爆炸这类必须被看见的事件。
func request(duration: float, ignore_cooldown: bool = false) -> bool:
	if duration <= 0.0:
		return false
	if cooldown_remaining > 0.0 and not ignore_cooldown:
		return false
	remaining = maxf(remaining, duration)
	cooldown_remaining = remaining + COOLDOWN_SECONDS
	return true

func advance(delta: float) -> void:
	var step := maxf(delta, 0.0)
	remaining = maxf(remaining - step, 0.0)
	cooldown_remaining = maxf(cooldown_remaining - step, 0.0)

func is_frozen() -> bool:
	return remaining > 0.0

func reset() -> void:
	remaining = 0.0
	cooldown_remaining = 0.0
