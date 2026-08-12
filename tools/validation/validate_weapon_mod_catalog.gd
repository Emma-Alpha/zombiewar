extends SceneTree

## 改装件资源目录的回归。
##
## 守四类会静默失效的配置错误：
##
## 1. **模型来自 docs/**。docs/** 在 export_presets.cfg 的 exclude_filter 里，
##    引用它的场景能通过编辑器、能通过 headless 验证、能通过 --export-release 且
##    不报错，但导入产物根本不进 pck ——线上白模。这是本仓库里最典型的
##    「所有本地验证全绿、只有玩家看得见」的失效模式，必须挡在源码层。
## 2. **weapon_mod_id 拼错**。不在 WeaponModTable.MOD_IDS 里就解析成 -1，
##    那件掉落变成「捡起来什么也不发生」，没有任何报错。
## 3. **带代价的改装件没有把代价写进文案**。玩家只会觉得"我捡了个东西然后变菜了"。
## 4. **中文文案缺字形**。UI 字体是子集，缺字在 Web 导出上渲染成豆腐块，
##    而这在桌面端会被系统字体回退掩盖、永远复现不了。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_weapon_mod_catalog.gd

const ModTable = preload("res://scripts/sim/weapon_mod_table.gd")
const MOD_DIRECTORY := "res://resources/mods"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var paths := _collect_mod_paths()
	_check("mod catalog must not be empty", not paths.is_empty())
	var seen_mods := {}
	for path in paths:
		_test_definition(path, seen_mods)
	# 每一种改装件至少要有一件掉落物代表它，否则表里的那一行是死代码。
	for mod_id in range(ModTable.COUNT):
		_check(
			"mod '%s' has no pickup representing it" % ModTable.MOD_IDS[mod_id],
			seen_mods.has(mod_id)
		)
	_test_map_wiring()
	_report()


func _collect_mod_paths() -> Array[String]:
	var paths: Array[String] = []
	var directory := DirAccess.open(MOD_DIRECTORY)
	if directory == null:
		return paths
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry.get_extension() == "tres":
			paths.append(MOD_DIRECTORY.path_join(entry))
		entry = directory.get_next()
	directory.list_dir_end()
	paths.sort()
	return paths


func _test_definition(path: String, seen_mods: Dictionary) -> void:
	var definition = load(path)
	_check("%s must load" % path, definition != null)
	if definition == null:
		return
	var label := path.get_file()

	_check(
		"%s: script must be attached (a .tres missing its `script =` line loads with every field null)" % label,
		definition.get_script() != null
	)
	if definition.get_script() == null:
		return

	_check("%s: must be a WEAPON_MOD reward" % label, definition.is_weapon_mod())
	var mod_id := ModTable.mod_index_from_id(definition.weapon_mod_id)
	_check(
		"%s: weapon_mod_id '%s' is not in WeaponModTable.MOD_IDS" % [label, definition.weapon_mod_id],
		mod_id >= 0
	)
	if mod_id < 0:
		return
	seen_mods[mod_id] = true

	_check(
		"%s: weapon_mod_stacks (%d) exceeds MAX_STACKS for '%s' (%d)" % [
			label, definition.weapon_mod_stacks, definition.weapon_mod_id,
			ModTable.MAX_STACKS[mod_id]
		],
		definition.weapon_mod_stacks <= ModTable.MAX_STACKS[mod_id]
	)

	# 视觉必须存在且必须来自 assets/。
	_check("%s: must define a view_scene" % label, definition.view_scene != null)
	if definition.view_scene != null:
		var view_path: String = definition.view_scene.resource_path
		_check(
			"%s: view_scene lives in docs/ (%s) — excluded from the Web export, ships as a missing model" % [
				label, view_path
			],
			not view_path.begins_with("res://docs/")
		)
		_check(
			"%s: view_scene must live under res://assets/ (got %s)" % [label, view_path],
			view_path.begins_with("res://assets/")
		)

	_check("%s: must have a display_name" % label, not definition.display_name.is_empty())
	_check("%s: must have effect_text so the player knows what it does" % label,
		not definition.effect_text.is_empty())

	# 带代价的改装件必须在文案里写出代价。
	var has_downside := (
		ModTable.BASE_SPREAD_ADD_MDEG[mod_id] > 0
		or ModTable.PENETRATION_ADD[mod_id] < 0
		or ModTable.DAMAGE_PERMILLE[mod_id] < 1000
	)
	if has_downside:
		_check(
			"%s: mod '%s' has a downside but effect_text does not mention it" % [
				label, definition.weapon_mod_id
			],
			definition.effect_text.contains("代价") or definition.effect_text.contains("-")
		)


## 掉落池里必须真的挂上了改装件，否则这套系统在实机里永远不出现。
func _test_map_wiring() -> void:
	var map_definition = load("res://resources/maps/demo/demo_map.tres")
	_check("demo map must load", map_definition != null)
	if map_definition == null:
		return
	var mod_drops := 0
	for rule in map_definition.zombie_death_rules:
		if rule == null:
			continue
		for group in rule.groups:
			if group == null:
				continue
			for event in group.events:
				if event != null and event.pickup != null and event.pickup.is_weapon_mod():
					mod_drops += 1
	_check(
		"the demo map must actually drop weapon mods (found %d entries)" % mod_drops,
		mod_drops > 0
	)


func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)


func _report() -> void:
	if failures.is_empty():
		print("validate_weapon_mod_catalog: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
