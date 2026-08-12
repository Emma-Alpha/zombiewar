extends SceneTree
func _init() -> void:
	var t = load("res://scripts/sim/weapon_mod_table.gd")
	print("table loaded: ", t != null)
	if t != null:
		print("  COUNT=", t.COUNT, " MAX_STACKS.size=", t.MAX_STACKS.size(), " ids=", t.MOD_IDS.size())
	var m = load("res://scripts/sim/weapon_mod_math.gd")
	print("math loaded: ", m != null)
	quit(0)
