extends Node

## 跨局进度（元层）：目前只有跨局累计材料货币。
## 局内材料在 sim_world（每局清零），这里存的是「累计入银行账户」的材料，
## 主菜单左上角显示用。只读单人局的结算，本地/联机不累加。

var SAVE_PATH := "user://meta_save.cfg"
const SECTION := "meta"
const KEY_BANKED := "banked_material"

var _banked_material := 0

func _ready() -> void:
	load_save()

func get_banked_material() -> int:
	return _banked_material

## amount 可为负；结果钳到非负并立即存盘。
func add_banked_material(amount: int) -> void:
	_banked_material = maxi(0, _banked_material + amount)
	save()

func load_save() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		_banked_material = int(cfg.get_value(SECTION, KEY_BANKED, 0))
	else:
		_banked_material = 0

func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION, KEY_BANKED, _banked_material)
	cfg.save(SAVE_PATH)
