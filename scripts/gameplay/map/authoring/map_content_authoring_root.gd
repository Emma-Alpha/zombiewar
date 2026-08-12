@tool
extends Node3D
class_name MapContentAuthoringRoot

@export_file("*.tres") var map_definition_path := ""
@export var managed_template_geometry := false
