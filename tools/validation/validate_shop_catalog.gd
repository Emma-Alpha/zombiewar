extends SceneTree

## 验证商店目录加载 + 条目合法性 + 确定性生成。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_shop_catalog.gd

const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
const DeterministicRngScript = preload("res://scripts/sim/deterministic_rng.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var catalog = ContentCatalogsScript.shop()
	_expect(catalog != null, "商店目录必须能加载", failures)
	if catalog == null:
		_finish(failures)
		return
	_expect(catalog.count() >= 5, "商店目录至少要有 5 个条目", failures)

	# 每个条目字段合法
	for i in range(catalog.count()):
		var offer = catalog.entry_at(i)
		_expect(offer != null, "条目 %d 不应为空" % i, failures)
		if offer != null:
			var errors := offer.validate_configuration()
			_expect(errors.is_empty(), "条目 %d 校验失败：%s" % [i, " ".join(errors)], failures)

	# 确定性生成：同一种子选出同一份、不重复、数量正确。
	var rng_a := DeterministicRngScript.new()
	rng_a.seed_streams(12345)
	var rng_b := DeterministicRngScript.new()
	rng_b.seed_streams(12345)
	var offers_a := _generate(catalog, rng_a, 3)
	var offers_b := _generate(catalog, rng_b, 3)
	_expect(offers_a.size() == 3, "应生成 3 个商品，实际 %d" % offers_a.size(), failures)
	_expect(offers_a.size() == offers_b.size(), "同种子生成数量应一致", failures)
	for i in range(offers_a.size()):
		_expect(
			offers_a[i] == offers_b[i],
			"同种子生成第 %d 项应一致" % i,
			failures
		)
	# 不重复
	var seen := {}
	for offer in offers_a:
		var key: String = offer.resource_path + ":" + offer.display_name
		_expect(not seen.has(key), "商品不应重复：%s" % offer.display_name, failures)
		seen[key] = true

	# 不同种子通常不同（至少不完全一样）
	var rng_c := DeterministicRngScript.new()
	rng_c.seed_streams(99999)
	var offers_c := _generate(catalog, rng_c, 3)
	var identical := offers_a.size() == offers_c.size()
	for i in range(offers_a.size()):
		if offers_a[i] != offers_c[i]:
			identical = false
			break
	_expect(not identical, "不同种子不应生成完全相同的商品", failures)

	if failures.is_empty():
		print("validate_shop_catalog: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_shop_catalog: %s" % failure)
	printerr("validate_shop_catalog: FAIL (%d)" % failures.size())
	quit(1)

## 从目录确定性选 count 个不重复条目（用 SHOP 流）。
func _generate(catalog: ShopCatalog, rng: DeterministicRng, count: int) -> Array:
	var pool: Array = []
	for i in range(catalog.count()):
		pool.append(catalog.entry_at(i))
	var result: Array = []
	for _i in range(mini(count, pool.size())):
		var idx := rng.next_uint32(DeterministicRngScript.Stream.SHOP) % pool.size()
		result.append(pool[idx])
		pool.remove_at(idx)
	return result

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_shop_catalog: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_shop_catalog: %s" % failure)
	printerr("validate_shop_catalog: FAIL (%d)" % failures.size())
	quit(1)
