extends RefCounted
class_name InventorySlot

## 固定容量属于背包规则；单个槽位只保存可变的运行时整数。
const SLOT_COUNT := 12

var profile_index: int = -1
var amount: int = 0


func is_empty() -> bool:
	return profile_index < 0


func clear() -> void:
	profile_index = -1
	amount = 0
