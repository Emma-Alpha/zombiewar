extends Node3D
class_name CombatFxPrewarmer

const FxWarmupContextScript = preload("res://scripts/fx/fx_warmup_context.gd")
const DEFAULT_FX_ROOT := "res://scenes/fx"

func discover_warmup_scene_paths(
	root_path: String = DEFAULT_FX_ROOT
) -> Array[String]:
	var candidates: Array[String] = []
	_collect_scene_paths(root_path, candidates)
	var warmup_paths: Array[String] = []
	for scene_path in candidates:
		if _supports_render_warmup(scene_path):
			warmup_paths.append(scene_path)
	warmup_paths.sort()
	return warmup_paths

func prewarm(camera: Camera3D) -> void:
	if camera == null:
		push_warning("Combat FX prewarm skipped: active camera missing")
		return
	var host := Node3D.new()
	host.name = "ActiveWarmupFx"
	add_child(host)
	var context := FxWarmupContextScript.new(camera, host) as FxWarmupContext
	var active_effects: Array[Node] = []
	for scene_path in discover_warmup_scene_paths():
		var packed := load(scene_path) as PackedScene
		if packed == null:
			push_warning("Unable to load warmup FX: %s" % scene_path)
			continue
		var effect := packed.instantiate()
		host.add_child(effect)
		effect.call("warmup_for_render", context)
		active_effects.append(effect)
	RenderingServer.force_draw(false, 0.0)
	RenderingServer.force_sync()
	for effect in active_effects:
		if not is_instance_valid(effect):
			continue
		effect.call("finish_render_warmup")
	host.free()

func _collect_scene_paths(
	root_path: String,
	paths: Array[String]
) -> void:
	var directory := DirAccess.open(root_path)
	if directory == null:
		push_warning("Unable to scan combat FX directory: %s" % root_path)
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if not entry.begins_with("."):
			var entry_path := root_path.path_join(entry)
			if directory.current_is_dir():
				_collect_scene_paths(entry_path, paths)
			elif entry.get_extension().to_lower() == "tscn":
				paths.append(entry_path)
		entry = directory.get_next()
	directory.list_dir_end()

func _supports_render_warmup(scene_path: String) -> bool:
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return false
	var effect := packed.instantiate()
	var supported := (
		effect.has_method("warmup_for_render") and
		effect.has_method("finish_render_warmup")
	)
	effect.free()
	return supported
