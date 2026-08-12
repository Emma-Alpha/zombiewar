extends RefCounted
class_name ContentCatalogs

## 两张内容目录的唯一加载点。
##
## 不做成 autoload，也不在 CharacterCatalog 自己身上 preload 目录 .tres：
## 那个 .tres 的 script 就是 CharacterCatalog，自己 preload 自己是一个循环引用。
## 一个不被任何 .tres 引用的访问器脚本没有这个问题。

const CHARACTER_CATALOG_PATH := "res://resources/characters/character_catalog.tres"
const MAP_CATALOG_PATH := "res://resources/maps/map_catalog.tres"

static var _characters: CharacterCatalog = null
static var _maps: MapDefinitionCatalog = null

static func characters() -> CharacterCatalog:
	if _characters == null:
		_characters = load(CHARACTER_CATALOG_PATH) as CharacterCatalog
	return _characters

static func maps() -> MapDefinitionCatalog:
	if _maps == null:
		_maps = load(MAP_CATALOG_PATH) as MapDefinitionCatalog
	return _maps
