extends SceneTree

## headless 自测：MetaProgression 跨局货币存档。
## 运行: godot --headless -s tools/validation/selftest_meta_progression.gd

func _init() -> void:
	var MPScript: GDScript = preload("res://scripts/meta/meta_progression.gd")
	var mp: Node = MPScript.new()
	# 用独立测试存档路径，避免污染真实存档
	mp.SAVE_PATH = "user://meta_save_test.cfg"
	if FileAccess.file_exists(mp.SAVE_PATH):
		DirAccess.remove_absolute(mp.SAVE_PATH)

	var ok := true
	ok = ok and _check(mp.get_banked_material() == 0, "初始为 0")
	mp.add_banked_material(150)
	ok = ok and _check(mp.get_banked_material() == 150, "累加 150")
	mp.add_banked_material(-50)
	ok = ok and _check(mp.get_banked_material() == 100, "减 50 → 100")
	mp.add_banked_material(-999)
	ok = ok and _check(mp.get_banked_material() == 0, "钳到非负")

	# 重新加载（模拟重启）应从磁盘读回
	mp.add_banked_material(77)
	var mp2: Node = MPScript.new()
	mp2.SAVE_PATH = "user://meta_save_test.cfg"
	mp2.load_save()
	ok = ok and _check(mp2.get_banked_material() == 77, "重启后读回 77")

	DirAccess.remove_absolute(mp.SAVE_PATH)
	print("SELFTEST meta_progression: %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)

func _check(cond: bool, label: String) -> bool:
	if not cond:
		printerr("  FAIL: %s" % label)
	return cond
