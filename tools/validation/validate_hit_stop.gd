extends SceneTree

## 表现层顿帧的回归。
##
## 这里守两件事，第二件比第一件重要：
## 1. 节流语义正确——尸潮里连续击杀不能把画面顿成幻灯片。
## 2. 顿帧**永远只碰表现层**。用 Engine.time_scale 做顿帧是这个功能最自然的写法，
##    也是本项目里最危险的写法：它会连同 SimClock 一起缩放，而各客户端击杀落在
##    各自的渲染帧上，顿帧起止时刻天然不同，于是每端用不同速度推进模拟。
##    同理顿帧不能冻结玩家——玩家坐标是模拟层的输入。这两条一旦被"简化"掉，
##    症状是联机对局慢慢漂移，而不是本地能看出来的 bug，所以必须由回归守住。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_hit_stop.gd

const HitStopStateScript = preload("res://scripts/fx/hit_stop_state.gd")
const ZombieTargetScene = preload("res://scenes/targets/ZombieTarget.tscn")

const HIT_STOP_SOURCE_PATH := "res://scripts/fx/hit_stop_state.gd"
const ARENA_SOURCE_PATH := "res://scripts/gameplay/gameplay_arena.gd"
const ZOMBIE_TARGET_SOURCE_PATH := "res://scripts/combat/zombie_target.gd"
const RENDERER_SOURCE_PATH := "res://scripts/render/zombie_renderer.gd"

var failures: Array[String] = []


func _initialize() -> void:
	_test_trigger_and_expiry()
	_test_cooldown_throttles_burst_kills()
	_test_simultaneous_requests_do_not_stack()
	_test_explosion_bypasses_cooldown()
	_test_duty_cycle_under_continuous_kills()
	_test_presentation_only_contract()
	await _test_frozen_zombie_stops_advancing()
	_report()


func _test_trigger_and_expiry() -> void:
	var state = HitStopStateScript.new()
	_check("idle state is not frozen", not state.is_frozen())
	_check("kill request triggers", state.request(HitStopStateScript.KILL_SECONDS))
	_check("request freezes the view", state.is_frozen())
	state.advance(HitStopStateScript.KILL_SECONDS * 0.5)
	_check("still frozen midway", state.is_frozen())
	state.advance(HitStopStateScript.KILL_SECONDS)
	_check("thaws after its duration", not state.is_frozen())


func _test_cooldown_throttles_burst_kills() -> void:
	var state = HitStopStateScript.new()
	state.request(HitStopStateScript.KILL_SECONDS)
	state.advance(HitStopStateScript.KILL_SECONDS)
	_check("thawed before the cooldown test", not state.is_frozen())
	_check(
		"a second kill inside the cooldown is refused",
		not state.request(HitStopStateScript.KILL_SECONDS)
	)
	_check("refused request does not freeze", not state.is_frozen())
	state.advance(HitStopStateScript.COOLDOWN_SECONDS)
	_check(
		"a kill after the cooldown triggers again",
		state.request(HitStopStateScript.KILL_SECONDS)
	)


func _test_simultaneous_requests_do_not_stack() -> void:
	# 模拟层一 tick 能打死一整片僵尸，每具尸体都会走一次 hit 事件。
	var state = HitStopStateScript.new()
	for _index in range(20):
		state.request(HitStopStateScript.KILL_SECONDS)
	_check(
		"a tick full of kills never exceeds one hit-stop",
		state.remaining <= HitStopStateScript.KILL_SECONDS + 0.0001
	)


func _test_explosion_bypasses_cooldown() -> void:
	var state = HitStopStateScript.new()
	state.request(HitStopStateScript.KILL_SECONDS)
	state.advance(HitStopStateScript.KILL_SECONDS)
	_check(
		"explosion punches through the cooldown",
		state.request(HitStopStateScript.EXPLOSION_SECONDS, true)
	)
	_check("explosion freezes the view", state.is_frozen())
	_check(
		"explosion hit-stop is the heavier one",
		HitStopStateScript.EXPLOSION_SECONDS > HitStopStateScript.KILL_SECONDS
	)


## 最坏情况：玩家每一帧都在击杀。顿帧占用的画面时间必须留在一个「有打击感」
## 而不是「掉帧」的比例内。
func _test_duty_cycle_under_continuous_kills() -> void:
	var state = HitStopStateScript.new()
	var step := 1.0 / 60.0
	var frames := 600
	var frozen_frames := 0
	for _index in range(frames):
		state.request(HitStopStateScript.KILL_SECONDS)
		if state.is_frozen():
			frozen_frames += 1
		state.advance(step)
	var duty_cycle := float(frozen_frames) / float(frames)
	_check(
		"continuous kills freeze under a quarter of the frames (was %.1f%%)" % (duty_cycle * 100.0),
		duty_cycle < 0.25
	)
	_check("continuous kills still produce hit-stop", duty_cycle > 0.05)


func _test_presentation_only_contract() -> void:
	for path in [HIT_STOP_SOURCE_PATH, ARENA_SOURCE_PATH, RENDERER_SOURCE_PATH, ZOMBIE_TARGET_SOURCE_PATH]:
		var source := FileAccess.get_file_as_string(path)
		_check("%s must be readable" % path, not source.is_empty())
		# 注释里讲得清为什么不能用，但代码里一次都不能出现。
		var code_lines := PackedStringArray()
		for line in source.split("\n"):
			var trimmed := line.strip_edges()
			if trimmed.begins_with("#"):
				continue
			code_lines.append(line)
		var code := "\n".join(code_lines)
		_check(
			"%s must not scale engine time for hit-stop" % path,
			not code.contains("time_scale") or path == ZOMBIE_TARGET_SOURCE_PATH
		)
	# ZombieTarget 允许出现 speed_scale（AnimationPlayer 的），但同样不许碰引擎时间。
	var zombie_source := FileAccess.get_file_as_string(ZOMBIE_TARGET_SOURCE_PATH)
	_check(
		"zombie target must not touch Engine.time_scale",
		not zombie_source.contains("Engine.time_scale")
	)
	var arena_source := FileAccess.get_file_as_string(ARENA_SOURCE_PATH)
	# 顿帧只能挡住渲染，绝不能挡住 tick 推进：_physics_process 里不得出现它。
	var physics_section := arena_source.get_slice("func _physics_process", 1).get_slice("\nfunc ", 0)
	_check(
		"hit-stop must not gate simulation ticks",
		not physics_section.contains("hit_stop")
	)
	_check(
		"hit-stop must gate the render path",
		arena_source.contains("hit_stop.is_frozen()")
	)
	# 玩家坐标是模拟层的输入，冻住本机玩家等于给各端喂不同的位置。
	var snapshot_section := arena_source.get_slice("func _push_player_snapshot", 1).get_slice("\nfunc ", 0)
	_check(
		"hit-stop must not gate the player snapshot fed to the simulation",
		not snapshot_section.contains("hit_stop")
	)


## 冻结中的僵尸必须真的停住：动画、受击摆动、缩放回弹、尸体留场倒计时全部暂停。
func _test_frozen_zombie_stops_advancing() -> void:
	var renderer_source := FileAccess.get_file_as_string(RENDERER_SOURCE_PATH)
	_check(
		"renderer must broadcast the freeze to near views",
		renderer_source.contains("func set_visual_frozen")
	)
	var zombie: ZombieTarget = ZombieTargetScene.instantiate()
	root.add_child(zombie)
	await process_frame
	zombie.bind_zombie(1, Vector3.ZERO, 0.0)
	zombie.play_hit_reaction(Vector3(0.2, 1.0, 0.0), Vector3(1.0, 0.0, 0.0))
	var reaction_before := zombie.hit_reaction_remaining
	_check("hit reaction is running before the freeze", reaction_before > 0.0)
	zombie.set_visual_frozen(true)
	await process_frame
	await process_frame
	_check(
		"frozen zombie does not burn its hit-reaction timer",
		is_equal_approx(zombie.hit_reaction_remaining, reaction_before)
	)
	zombie.set_visual_frozen(false)
	await process_frame
	_check(
		"thawed zombie resumes its hit-reaction timer",
		zombie.hit_reaction_remaining < reaction_before
	)
	zombie.set_visual_frozen(false)
	# play_hit_reaction 会起受击音；不停掉就带着还在播的 AudioStreamPlayback 退出。
	for candidate in zombie.find_children("*", "AudioStreamPlayer3D", true, false):
		var audio := candidate as AudioStreamPlayer3D
		audio.stop()
		audio.stream = null
	root.remove_child(zombie)
	zombie.free()
	# 音频播放实例要等一帧才被 AudioServer 回收，否则脚本退出时会报泄漏。
	await process_frame
	await process_frame


func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)


func _report() -> void:
	if failures.is_empty():
		print("validate_hit_stop: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
