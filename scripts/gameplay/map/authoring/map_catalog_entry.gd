extends Resource
class_name MapCatalogEntry

@export var map_id: StringName
@export var entry_scene: PackedScene
@export var display_name := "地图"
@export_multiline var description := ""
@export var cover: Texture2D
@export var sort_order := 0
