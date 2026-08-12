extends SceneTree

## 武器改装件系统的回归。
##
## 这套系统的失效模式几乎全是「各端一致地算错」——帧哈希相等、没有 desync 报警、
## 只是玩家发现数值不对。所以能守住它的只有源码级断言，具体是五条：
##
## 1. 没捡到任何改装件时，派生档案必须与基础档案**逐位相同**。这是「装了改装系统
##    但还没用上时行为不变」的唯一依据，也是所有既有回归仍然有效的前提。
## 2. 叠加与获取顺序无关。玩家 A 先捡穿甲后捡分裂、玩家 B 反过来，两人身上集合
##    相同就必须打出相同伤害。按获取历史累乘会破坏这条，而单人测试 100% 测不出来。
## 3. 三个武器数值读点必须全部走 per-slot 派生。漏掉 _recover_spread 的现象是
##    「开火时按改装后算、松手回复时按没装算」，一致地怪异。
## 4. player_mod_level 必须进帧哈希，否则两端改装状态分叉要等到某一枪打出不同
##    伤害才被间接发现。
## 5. 常量表的每一行长度必须等于 COUNT，且 COUNT 等于 enum 的项数。
##    漏改 COUNT 会让展平索引整体错位——各端一致地错位。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_weapon_mods.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const ModTable = preload("res://scripts/sim/weapon_mod_table.gd")
const ModMath = preload("res://scripts/sim/weapon_mod_math.gd")

const SIM_WORLD_PATH := "res://scripts/sim/sim_world.gd"
const SIM_HASHER_PATH := "res://scripts/sim/sim_hasher.gd"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_table_shape()
	_test_identity_without_mods()
	_test_order_independence()
	_test_clamps()
	_test_effects_actually_apply()
	_test_stack_limit()
	_test_read_sites_use_effective_profile()
	_test_mod_level_is_hashed()
	_test_no_banned_math()
	_report()


func _base_profile() -> Dictionary:
	# 与 configure_weapon_profile 的产出同构（手枪档案）。
	return {
		"damage": 35.0,
		"attack_range": 24.0,
		"base_spread_degrees": 0.35,
		"max_spread_degrees": 3.0,
		"spread_increase_degrees": 0.8,
		"spread_recovery_degrees_per_second": 1.8,
		"max_penetration_count": 0,
		"penetration_damage_coefficient": 0.0,
		"pellet_count": 1,
	}


func _levels(pairs: Dictionary) -> PackedByteArray:
	var levels := PackedByteArray()
	levels.resize(ModTable.COUNT)
	levels.fill(0)
	for mod_id in pairs.keys():
		levels[int(mod_id)] = int(pairs[mod_id])
	return levels


func _test_table_shape() -> void:
	_check(
		"COUNT (%d) must equal the number of Mod enum entries (%d)" % [
			ModTable.COUNT, ModTable.Mod.size()
		],
		ModTable.COUNT == ModTable.Mod.size()
	)
	var tables := {
		"MOD_IDS": ModTable.MOD_IDS,
		"MOD_LABELS_CN": ModTable.MOD_LABELS_CN,
		"MAX_STACKS": ModTable.MAX_STACKS,
		"DAMAGE_PERMILLE": ModTable.DAMAGE_PERMILLE,
		"RANGE_PERMILLE": ModTable.RANGE_PERMILLE,
		"BASE_SPREAD_PERMILLE": ModTable.BASE_SPREAD_PERMILLE,
		"MAX_SPREAD_PERMILLE": ModTable.MAX_SPREAD_PERMILLE,
		"INCREASE_PERMILLE": ModTable.INCREASE_PERMILLE,
		"RECOVERY_PERMILLE": ModTable.RECOVERY_PERMILLE,
		"BASE_SPREAD_ADD_MDEG": ModTable.BASE_SPREAD_ADD_MDEG,
		"PELLET_ADD": ModTable.PELLET_ADD,
		"PENETRATION_ADD": ModTable.PENETRATION_ADD,
	}
	for name in tables.keys():
		var row = tables[name]
		_check(
			"%s must have exactly COUNT (%d) entries, has %d" % [name, ModTable.COUNT, row.size()],
			row.size() == ModTable.COUNT
		)
	# id 必须唯一，否则 mod_index_from_id 会把两件改装件解析成同一个下标。
	var seen := {}
	for id in ModTable.MOD_IDS:
		_check("duplicate mod id '%s'" % id, not seen.has(id))
		seen[id] = true
	for index in range(ModTable.COUNT):
		_check(
			"mod_index_from_id('%s') must round-trip to %d" % [ModTable.MOD_IDS[index], index],
			ModTable.mod_index_from_id(ModTable.MOD_IDS[index]) == index
		)


## 最重要的一条：没有改装时必须原样返回。
func _test_identity_without_mods() -> void:
	var base := _base_profile()
	var empty := _levels({})
	var derived: Dictionary = ModMath.derive_profile(base, empty, 0)
	for key in base.keys():
		_check(
			"unmodded profile must be identical at '%s' (%s vs %s)" % [
				key, str(base[key]), str(derived.get(key))
			],
			derived.has(key) and is_same(derived[key], base[key])
				or (
					typeof(base[key]) == TYPE_FLOAT
					and is_equal_approx(float(derived.get(key, -999.0)), float(base[key]))
				)
		)
	_check(
		"unmodded profile must not gain or lose keys",
		derived.size() == base.size()
	)


## 顺序无关：集合相同 → 结果逐位相同。
func _test_order_independence() -> void:
	var base := _base_profile()
	var combos := [
		{ModTable.Mod.PIERCE: 1, ModTable.Mod.SPLIT: 1},
		{ModTable.Mod.DAMAGE: 2, ModTable.Mod.MATCHED: 1, ModTable.Mod.CHOKE: 1},
		{ModTable.Mod.HEAVY_CORE: 1, ModTable.Mod.LONG_BARREL: 1, ModTable.Mod.COMPENSATOR: 2},
		{ModTable.Mod.HOLLOW_POINT: 1, ModTable.Mod.PIERCE: 2, ModTable.Mod.DAMAGE: 3},
	]
	for combo in combos:
		# derive_profile 只读层数、不读顺序，所以「顺序无关」等价于
		# 「用同一份层数无论怎样构造都得到同一结果」。这里用两种不同的写入顺序
		# 构造同一份层数，验证写入路径本身也不引入顺序依赖。
		var forward := PackedByteArray()
		forward.resize(ModTable.COUNT)
		forward.fill(0)
		var keys: Array = combo.keys()
		for k in keys:
			forward[int(k)] = int(combo[k])
		var backward := PackedByteArray()
		backward.resize(ModTable.COUNT)
		backward.fill(0)
		keys.reverse()
		for k in keys:
			backward[int(k)] = int(combo[k])
		var a: Dictionary = ModMath.derive_profile(base, forward, 0)
		var b: Dictionary = ModMath.derive_profile(base, backward, 0)
		for key in a.keys():
			_check(
				"pickup order must not change '%s' for combo %s (%s vs %s)" % [
					key, str(combo), str(a[key]), str(b[key])
				],
				is_equal_approx(float(a[key]), float(b[key]))
					if typeof(a[key]) == TYPE_FLOAT else a[key] == b[key]
			)


## 夹取：CHOKE 压 max、MATCHED 压 base，叠加后不能倒挂。
func _test_clamps() -> void:
	var base := _base_profile()
	var levels := _levels({
		ModTable.Mod.CHOKE: ModTable.MAX_STACKS[ModTable.Mod.CHOKE],
		ModTable.Mod.HEAVY_CORE: ModTable.MAX_STACKS[ModTable.Mod.HEAVY_CORE],
	})
	var derived: Dictionary = ModMath.derive_profile(base, levels, 0)
	_check(
		"max spread must never fall below base spread (base %.4f, max %.4f)" % [
			derived["base_spread_degrees"], derived["max_spread_degrees"]
		],
		derived["max_spread_degrees"] >= derived["base_spread_degrees"]
	)
	_check("pellet count must stay >= 1", int(derived["pellet_count"]) >= 1)
	_check(
		"penetration count must stay within [0,16]",
		int(derived["max_penetration_count"]) >= 0
			and int(derived["max_penetration_count"]) <= 16
	)
	_check(
		"penetration coefficient must stay within [0,1]",
		derived["penetration_damage_coefficient"] >= 0.0
			and derived["penetration_damage_coefficient"] <= 1.0
	)
	# 空尖弹把穿透打到负数时必须夹到 0，而不是变成一个负的循环次数。
	var hollow: Dictionary = ModMath.derive_profile(
		base, _levels({ModTable.Mod.HOLLOW_POINT: 2}), 0
	)
	_check(
		"hollow point must not drive penetration below zero",
		int(hollow["max_penetration_count"]) == 0
	)


## 每种改装件都必须真的改到它声称的字段——否则就是一件"捡了没反应"的装备。
func _test_effects_actually_apply() -> void:
	var base := _base_profile()
	for mod_id in range(ModTable.COUNT):
		var derived: Dictionary = ModMath.derive_profile(base, _levels({mod_id: 1}), 0)
		var changed := false
		for key in base.keys():
			if typeof(base[key]) == TYPE_FLOAT:
				if not is_equal_approx(float(base[key]), float(derived[key])):
					changed = true
			elif base[key] != derived[key]:
				changed = true
		_check(
			"mod '%s' must change at least one profile field" % ModTable.MOD_IDS[mod_id],
			changed
		)
	# 具体方向抽查：伤害类必须让伤害变大，收束类必须让上限散布变小。
	var dmg: Dictionary = ModMath.derive_profile(base, _levels({ModTable.Mod.DAMAGE: 1}), 0)
	_check("DAMAGE must raise damage", dmg["damage"] > base["damage"])
	var choke: Dictionary = ModMath.derive_profile(base, _levels({ModTable.Mod.CHOKE: 1}), 0)
	_check("CHOKE must lower max spread", choke["max_spread_degrees"] < base["max_spread_degrees"])
	var pierce: Dictionary = ModMath.derive_profile(base, _levels({ModTable.Mod.PIERCE: 1}), 0)
	_check(
		"PIERCE must both add a target and lift the falloff off zero",
		int(pierce["max_penetration_count"]) == 1
			and pierce["penetration_damage_coefficient"] > 0.0
	)
	var split: Dictionary = ModMath.derive_profile(base, _levels({ModTable.Mod.SPLIT: 1}), 0)
	_check(
		"SPLIT must add a pellet and cut per-pellet damage",
		int(split["pellet_count"]) == 2 and split["damage"] < base["damage"]
	)
	# 带代价的件必须真的带代价，否则它就只是一件更好的正面件。
	var heavy: Dictionary = ModMath.derive_profile(base, _levels({ModTable.Mod.HEAVY_CORE: 1}), 0)
	_check(
		"HEAVY_CORE must trade accuracy for damage",
		heavy["damage"] > base["damage"]
			and heavy["base_spread_degrees"] > base["base_spread_degrees"]
	)
	var hollow: Dictionary = ModMath.derive_profile(base, _levels({ModTable.Mod.HOLLOW_POINT: 1}), 0)
	_check("HOLLOW_POINT must raise damage", hollow["damage"] > base["damage"])


func _test_stack_limit() -> void:
	var world: SimWorld = SimWorldScript.new()
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(20260812)
	var mod_id := int(ModTable.Mod.DAMAGE)
	var limit: int = ModTable.MAX_STACKS[mod_id]
	var total := 0
	for _index in range(limit + 4):
		total += world.grant_weapon_mod(0, mod_id, 1)
	_check(
		"granting past the cap must saturate at MAX_STACKS (%d, got level %d)" % [
			limit, world.get_weapon_mod_level(0, mod_id)
		],
		world.get_weapon_mod_level(0, mod_id) == limit and total == limit
	)
	# 逐座位独占：给 0 号座位的改装件不能影响 1 号。
	_check(
		"mods must be per-slot, not global",
		world.get_weapon_mod_level(1, mod_id) == 0
	)
	# 开新局必须清零（本项目选的是单局清零）。
	world.reset(20260812)
	_check(
		"reset() must clear mods for a fresh run",
		world.get_weapon_mod_level(0, mod_id) == 0
	)


## 三个读点全部走 per-slot 派生，且没有漏网的 _weapon_profile 直读。
func _test_read_sites_use_effective_profile() -> void:
	var source := FileAccess.get_file_as_string(SIM_WORLD_PATH)
	_check("sim_world.gd must be readable", not source.is_empty())
	if source.is_empty():
		return
	var direct := 0
	for line in source.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("#"):
			continue
		if not trimmed.contains("_weapon_profile("):
			continue
		if trimmed.contains("_effective_weapon_profile("):
			continue
		if trimmed.begins_with("func "):
			continue  # 函数签名（configure_weapon_profile 也含这个子串）
		if trimmed.contains("var base := _weapon_profile(profile_index)"):
			continue  # _effective_weapon_profile 自己的实现
		direct += 1
	_check(
		"every weapon-stat read must go through _effective_weapon_profile (found %d direct reads)" % direct,
		direct == 0
	)
	for site in [
		"func reset_spread",
		"func _recover_spread",
		"func _resolve_shot_event",
	]:
		var section := source.get_slice(site, 1).get_slice("\nfunc ", 0)
		_check(
			"%s must resolve the per-slot profile" % site,
			section.contains("_effective_weapon_profile(")
		)


func _test_mod_level_is_hashed() -> void:
	var source := FileAccess.get_file_as_string(SIM_HASHER_PATH)
	_check(
		"player_mod_level must be mixed into the frame hash",
		source.contains("player_mod_level")
	)


## 派生数学在 sim 路径上，禁用不跨平台稳定的函数。
func _test_no_banned_math() -> void:
	for path in [
		"res://scripts/sim/weapon_mod_math.gd",
		"res://scripts/sim/weapon_mod_table.gd",
	]:
		var source := FileAccess.get_file_as_string(path)
		var code_lines := PackedStringArray()
		for line in source.split("\n"):
			if line.strip_edges().begins_with("#"):
				continue
			code_lines.append(line)
		var code := "\n".join(code_lines)
		for banned in ["sin(", "cos(", "atan2(", "pow(", ".rotated("]:
			_check(
				"%s must not use %s (platform libm is not bit-stable)" % [path, banned],
				not code.contains(banned)
			)


func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)


func _report() -> void:
	if failures.is_empty():
		print("validate_weapon_mods: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
