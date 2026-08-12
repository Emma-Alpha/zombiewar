extends RefCounted
class_name ContentCatalogs

## 两张内容目录的唯一加载点。
##
## 不做成 autoload，也不在 CharacterCatalog 自己身上 preload 目录 .tres：
## 那个 .tres 的 script 就是 CharacterCatalog，自己 preload 自己是一个循环引用。
## 一个不被任何 .tres 引用的访问器脚本没有这个问题。

const CHARACTER_CATALOG_PATH := "res://resources/characters/character_catalog.tres"
const MAP_CATALOG_PATH := "res://resources/maps/map_catalog.tres"
const SHOP_CATALOG_PATH := "res://resources/shop/shop_catalog.tres"

static var _characters: CharacterCatalog = null
static var _maps: MapDefinitionCatalog = null
static var _shop: ShopCatalog = null

static func characters() -> CharacterCatalog:
	if _characters == null:
		_characters = load(CHARACTER_CATALOG_PATH) as CharacterCatalog
	return _characters

static func maps() -> MapDefinitionCatalog:
	if _maps == null:
		_maps = load(MAP_CATALOG_PATH) as MapDefinitionCatalog
	return _maps

static func shop() -> ShopCatalog:
	if _shop == null:
		_shop = load(SHOP_CATALOG_PATH) as ShopCatalog
	return _shop
