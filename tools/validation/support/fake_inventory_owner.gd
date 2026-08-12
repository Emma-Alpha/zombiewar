extends RefCounted

## 最小验证宿主：后续背包组件可以拥有这些槽位，但本任务不引入组件或 UI。
var slots: Array[RefCounted] = []


func build_slots(slot_script: Script, slot_count: int) -> void:
	slots.clear()
	for _index in range(slot_count):
		slots.append(slot_script.new() as RefCounted)
