extends SceneTree

## 验证角色三围能正确应用到 PlayerController。
##
## spawner 在 add_child（触发 _ready）之前调 apply_character_definition，
## 此时 health 仍为 null——本脚本复现这个时序：先 apply（health=null 分支），
## 再触发 _ready（_ensure_health_initialized 用新 max_health 建 Health），
## 最后断言 max_health / move_speed / health.current 符合角色数据。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_character_stats_apply.gd

const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")

const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var catalog = ContentCatalogsScript.characters()
	_expect(catalog != null, "角色目录必须能加载", failures)
	if catalog == null:
		_finish(failures)
		return

	# 防爆（survivor_green）：生命 +40 → 140，移速 ×0.8 → 4.0
	var green = catalog.get_by_id(&"survivor_green")
	_expect(green != null, "survivor_green 必须存在于目录", failures)
	if green != null:
		_check_player(green, 140.0, 4.0, "防爆", failures)

	# 医疗（survivor_blue）：生命 -15 → 85，移速 ×1.05 → 5.25
	var blue = catalog.get_by_id(&"survivor_blue")
	_expect(blue != null, "survivor_blue 必须存在于目录", failures)
	if blue != null:
		_check_player(blue, 85.0, 5.25, "医疗", failures)

	# 突击（survivor_red）：生命 +0 → 100，移速 ×0.92 → 4.6
	var red = catalog.get_by_id(&"survivor_red")
	_expect(red != null, "survivor_red 必须存在于目录", failures)
	if red != null:
		_check_player(red, 100.0, 4.6, "突击", failures)

	_finish(failures)

func _check_player(
	def: CharacterDefinition,
	expected_health: float,
	expected_speed: float,
	label: String,
	failures: Array[String]
) -> void:
	var player := PLAYER_SCENE.instantiate()
	_expect(player != null, "%s：Player.tscn 实例化失败" % label, failures)
	if player == null:
		return
	# 复现 spawner 时序：add_child（_ready）之前 apply。
	player.apply_character_definition(def)
	_expect(
		is_equal_approx(player.max_health, expected_health),
		"%s：apply 后 max_health 应为 %f，实际 %f" % [
			label, expected_health, player.max_health
		],
		failures
	)
	_expect(
		is_equal_approx(player.move_speed, expected_speed),
		"%s：apply 后 move_speed 应为 %f，实际 %f" % [
			label, expected_speed, player.move_speed
		],
		failures
	)
	# 触发 _ready：_ensure_health_initialized 用新 max_health 建 Health。
	root.add_child(player)
	_expect(
		player.health != null,
		"%s：_ready 后 health 必须已初始化" % label,
		failures
	)
	if player.health != null:
		_expect(
			is_equal_approx(player.health.maximum, expected_health),
			"%s：health.maximum 应为 %f，实际 %f" % [
				label, expected_health, player.health.maximum
			],
			failures
		)
		_expect(
			is_equal_approx(player.health.current, expected_health),
			"%s：health.current 应为满值 %f，实际 %f" % [
				label, expected_health, player.health.current
			],
			failures
		)
	player.queue_free()

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_character_stats_apply: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_character_stats_apply: %s" % failure)
	printerr("validate_character_stats_apply: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
