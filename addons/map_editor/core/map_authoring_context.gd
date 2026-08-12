extends RefCounted
class_name MapAuthoringContext


static func load_from_root(
	root: Node3D,
	map_catalog_path: String
) -> Dictionary:
	if not root is MapContentAuthoringRoot:
		return {"error": ERR_INVALID_DATA, "message": "当前场景不是地图内容场景"}
	var definition_path := (root as MapContentAuthoringRoot).map_definition_path
	var definition := load(definition_path) as MapDefinition
	if definition == null:
		return {"error": ERR_FILE_NOT_FOUND, "message": "无法加载 %s" % definition_path}
	var catalog := load(map_catalog_path) as MapCatalog
	if catalog == null:
		return {"error": ERR_FILE_NOT_FOUND, "message": "无法加载 %s" % map_catalog_path}
	return {
		"error": OK,
		"definition": definition,
		"definition_path": definition_path,
		"map_catalog": catalog,
		"map_catalog_path": map_catalog_path,
	}
