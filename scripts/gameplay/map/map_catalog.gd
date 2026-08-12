extends Resource
class_name MapDefinitionCatalog

## 按 id 索引的**运行时**地图目录：联机下服务端下发 map_id，各端据此解析同一张图。
## 语义与 CharacterCatalog 完全一致：只认 StringName id，未知 id 返回 null 而不回退。
##
## 注意与 scripts/gameplay/map/authoring/map_catalog.gd 的 MapCatalog 区分：
## 那个是**创作期**目录（装 MapCatalogEntry，供地图编辑器与地图选择界面用），
## 这个装的是 MapDefinition 本体。两者都叫 MapCatalog 会撞全局类名，
## 所以运行时这个改叫 MapDefinitionCatalog。

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
