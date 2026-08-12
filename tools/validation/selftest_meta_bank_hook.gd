extends SceneTree

## headless 自测：MetaBanker 累加判定逻辑。
## 运行: godot --headless -s tools/validation/selftest_meta_bank_hook.gd

func _init() -> void:
	var B: GDScript = preload("res://scripts/meta/meta_banker.gd")
	var ok := true
	ok = ok and _c(B.compute_banked(0, false, 120) == 120, "单人+120")
	ok = ok and _c(B.compute_banked(0, false, 0) == 0, "单人+0")
	ok = ok and _c(B.compute_banked(1, false, 120) == 0, "本地多人不累加")
	ok = ok and _c(B.compute_banked(2, true, 120) == 0, "联机不累加")
	ok = ok and _c(B.compute_banked(0, false, -5) == 0, "负值钳到 0")
	print("SELFTEST meta_bank_hook: %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)

func _c(cond: bool, label: String) -> bool:
	if not cond:
		printerr("  FAIL: %s" % label)
	return cond
