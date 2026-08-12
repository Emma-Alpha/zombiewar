extends Resource
class_name MapCatalog

## 按 id 索引的地图目录。语义与 CharacterCatalog 完全一致：
## 只认 StringName id，未知 id 返回 null 而不回退。

@export var entries: Array[MapDefinition] = []

func default_id() -> StringName:
	if entries.is_empty():
		return &""
	return entries[0].map_id

func ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for definition in entries:
		if definition != null:
			result.append(definition.map_id)
	return result

func has_id(id: StringName) -> bool:
	return get_by_id(id) != null

func get_by_id(id: StringName) -> MapDefinition:
	for definition in entries:
		if definition != null and definition.map_id == id:
			return definition
	return null
