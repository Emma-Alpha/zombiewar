extends Resource
class_name CharacterCatalog

## 按 id 索引的角色目录。
##
## 对外只认 StringName id，不认数组下标：下标会随目录顺序变化，
## 而 id 不会——往目录中间插一个角色不该让别人的编号跟着挪位。

@export var entries: Array[CharacterDefinition] = []

func default_id() -> StringName:
	if entries.is_empty():
		return &""
	return entries[0].character_id

func ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for definition in entries:
		if definition != null:
			result.append(definition.character_id)
	return result

func has_id(id: StringName) -> bool:
	return get_by_id(id) != null

## 未知 id 返回 null，绝不回退到默认角色。
## 回退会把「两端目录不一致」变成一次静默的外观分叉；调用方必须自己决定
## 是显示错误还是拒绝入局。
func get_by_id(id: StringName) -> CharacterDefinition:
	for definition in entries:
		if definition != null and definition.character_id == id:
			return definition
	return null

## 循环切换。step 为 +1/-1，超出两端时绕回。
func next_id(from: StringName, step: int) -> StringName:
	if entries.is_empty():
		return &""
	var index := 0
	for candidate in range(entries.size()):
		if entries[candidate] != null and entries[candidate].character_id == from:
			index = candidate
			break
	var count := entries.size()
	var next_index := ((index + step) % count + count) % count
	return entries[next_index].character_id
