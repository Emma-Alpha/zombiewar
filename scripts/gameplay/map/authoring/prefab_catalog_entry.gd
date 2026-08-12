extends Resource
class_name PrefabCatalogEntry

enum Kind { DECORATION, OBSTACLE, EXPLOSIVE_BARREL }

@export var prefab_id: StringName
@export var display_name := "预制件"
@export var category: StringName = &"misc"
@export var search_tags := PackedStringArray()
@export var scene: PackedScene
@export var thumbnail: Texture2D
@export var kind := Kind.DECORATION
