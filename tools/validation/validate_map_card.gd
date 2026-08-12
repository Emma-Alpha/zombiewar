extends SceneTree

## 地图卡组件的校验。
##
## 两件事：难度星必须真的按 difficulty 点亮，缺缩略图时必须画占位而不是留空洞；
## 以及只有可编辑（房主）时点击才发出换图请求——把「谁能换图」的判断交给一处。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_map_card.gd

const MAP_CARD_SCENE_PATH := "res://scenes/menu/MapCard.tscn"
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(ResourceLoader.exists(MAP_CARD_SCENE_PATH), "MapCard 场景必须存在", failures)
	if not failures.is_empty():
		_finish(failures)
		return

	var scene := load(MAP_CARD_SCENE_PATH) as PackedScene
	var card = scene.instantiate()
	root.add_child(card)
	await process_frame

	var catalog = ContentCatalogsScript.maps()
	var demo = catalog.get_by_id(catalog.default_id())

	card.set_map(demo, false)
	await process_frame
	_expect(
		(card.get_node("%MapNameLabel") as Label).text == demo.display_name,
		"地图卡要显示地图名",
		failures
	)
	var stars := card.get_node("%DifficultyRow") as HBoxContainer
	var lit := 0
	for star in stars.get_children():
		# 难度用 ColorRect 而不是字形：字体子集里没有「●」，而缺字形只在
		# Web 导出上现形，桌面端会被系统字体回退掩盖。
		_expect(star is ColorRect, "难度星必须是 ColorRect 而不是带字形的 Label", failures)
		if (star as ColorRect).modulate.a > 0.9:
			lit += 1
	_expect(
		lit == demo.difficulty,
		"点亮的难度星必须等于 difficulty：期望 %d，实际 %d" % [demo.difficulty, lit],
		failures
	)
	_expect(stars.get_child_count() == 5, "难度星总数固定为 5", failures)

	# 缺缩略图时画占位色块，不留空洞。
	if demo.thumbnail == null:
		_expect(
			card.get_node("%ThumbnailPlaceholder").visible,
			"缺缩略图时必须显示占位块",
			failures
		)
		_expect(
			not (card.get_node("%Thumbnail") as TextureRect).visible,
			"缺缩略图时不显示空 TextureRect",
			failures
		)

	# 只读时点击不发请求。用字典接住计数：GDScript 的 lambda 按值捕获局部变量。
	var observed := {"requests": 0}
	card.map_change_requested.connect(func(): observed["requests"] += 1)
	card._on_pressed()
	_expect(observed["requests"] == 0, "非房主点击地图卡不得发出换图请求", failures)
	_expect(not card.get_node("%ChangeHint").visible, "非房主不显示换图提示", failures)

	card.set_map(demo, true)
	await process_frame
	_expect(card.get_node("%ChangeHint").visible, "房主要看到换图提示", failures)
	card._on_pressed()
	_expect(observed["requests"] == 1, "房主点击地图卡必须发出换图请求", failures)

	# 空地图必须有可读的兜底，而不是空白卡。
	card.set_map(null, false)
	await process_frame
	_expect(
		(card.get_node("%MapNameLabel") as Label).text.strip_edges() != "",
		"没有地图时也要有可读文案",
		failures
	)

	card.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_map_card: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_map_card: %s" % failure)
	printerr("validate_map_card: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
