extends Node3D
class_name GroundBloodManager

const SPLAT_SCENE := preload("res://scenes/fx/GroundBloodSplat.tscn")
const HIT_TEXTURES: Array[Texture2D] = [
	preload("res://assets/fx/blood/kenney_splat26.png"),
	preload("res://assets/fx/blood/kenney_splat29.png"),
	preload("res://assets/fx/blood/kenney_splat34.png"),
]
const TRAIL_TEXTURES: Array[Texture2D] = [
	preload("res://assets/fx/blood/kenney_splat20.png"),
	preload("res://assets/fx/blood/kenney_splat29.png"),
]

@export_range(1, 512, 1) var max_splats := 192
@export_flags_3d_physics var surface_collision_mask := 1
@export var spatial_cell_size := 0.45
@export_range(1, 2, 1) var max_layers_per_cell := 2

var splats: Array[GroundBloodSplat] = []
var reuse_cursor := 0
var cell_splats: Dictionary = {}
var splat_cells: Dictionary = {}

func place_splat(
	surface_position: Vector3,
	surface_normal: Vector3,
	size: Vector2,
	rotation_radians: float,
	tint: Color,
	texture: Texture2D,
	roughness: float
) -> GroundBloodSplat:
	var cell := _cell_for_position(surface_position)
	var existing_layers: Array = cell_splats.get(cell, [])
	if existing_layers.size() >= maxi(max_layers_per_cell, 1):
		var merged := existing_layers[0] as GroundBloodSplat
		merged.merge_limited(1.15, 0.015)
		return merged

	var splat := _acquire_splat()
	_unregister_splat(splat)
	splat.setup(
		surface_position,
		surface_normal,
		size,
		rotation_radians,
		tint,
		texture,
		roughness
	)
	_register_splat(splat, cell)
	return splat

func spawn_hit_splat(
	hit_position: Vector3,
	shot_direction: Vector3,
	intensity: float = 1.0
) -> GroundBloodSplat:
	var surface := _find_blood_surface(hit_position)
	if surface.is_empty():
		return null
	var resolved_intensity := clampf(intensity, 0.75, 1.35)
	var diameter := minf(randf_range(0.9, 1.25) * resolved_intensity, 1.4)
	return place_splat(
		surface["position"],
		surface["normal"],
		Vector2.ONE * diameter,
		randf_range(-PI, PI),
		Color(0.42, 0.008, 0.015, randf_range(0.86, 0.96)),
		HIT_TEXTURES.pick_random(),
		randf_range(0.32, 0.42)
	)

func spawn_trail_splat(
	world_position: Vector3,
	move_direction: Vector3,
	intensity: float,
	progress: float
) -> GroundBloodSplat:
	var surface := _find_blood_surface(world_position)
	if surface.is_empty():
		return null
	var resolved_progress := clampf(progress, 0.0, 1.0)
	var resolved_intensity := clampf(intensity, 0.75, 1.35)
	var width := lerpf(0.45, 0.28, resolved_progress) * resolved_intensity
	var length := lerpf(0.8, 0.5, resolved_progress) * resolved_intensity
	var rotation_radians := atan2(move_direction.x, move_direction.z)
	rotation_radians += randf_range(-0.12, 0.12)
	return place_splat(
		surface["position"],
		surface["normal"],
		Vector2(width, length),
		rotation_radians,
		Color(0.38, 0.006, 0.012, lerpf(0.92, 0.82, resolved_progress)),
		TRAIL_TEXTURES.pick_random(),
		lerpf(0.45, 0.6, resolved_progress)
	)

func spawn_death_pool(
	world_position: Vector3,
	intensity: float = 1.0
) -> GroundBloodSplat:
	var surface := _find_blood_surface(world_position)
	if surface.is_empty():
		return null
	var resolved_intensity := clampf(intensity, 0.8, 1.35)
	var size := Vector2(
		randf_range(1.15, 1.4),
		randf_range(1.15, 1.4)
	) * resolved_intensity
	return place_splat(
		surface["position"],
		surface["normal"],
		size,
		randf_range(-PI, PI),
		Color(0.36, 0.004, 0.01, 0.95),
		HIT_TEXTURES.pick_random(),
		randf_range(0.34, 0.44)
	)

func _acquire_splat() -> GroundBloodSplat:
	if splats.size() < maxi(max_splats, 1):
		var created := SPLAT_SCENE.instantiate() as GroundBloodSplat
		add_child(created)
		splats.append(created)
		return created
	var reused := splats[reuse_cursor]
	reuse_cursor = (reuse_cursor + 1) % splats.size()
	return reused

func _cell_for_position(world_position: Vector3) -> Vector2i:
	var cell_size := maxf(spatial_cell_size, 0.001)
	return Vector2i(
		floori(world_position.x / cell_size),
		floori(world_position.z / cell_size)
	)

func _register_splat(splat: GroundBloodSplat, cell: Vector2i) -> void:
	var layers: Array = cell_splats.get(cell, [])
	layers.append(splat)
	cell_splats[cell] = layers
	splat_cells[splat.get_instance_id()] = cell

func _unregister_splat(splat: GroundBloodSplat) -> void:
	var splat_id := splat.get_instance_id()
	if not splat_cells.has(splat_id):
		return
	var old_cell := splat_cells[splat_id] as Vector2i
	var old_layers: Array = cell_splats.get(old_cell, [])
	old_layers.erase(splat)
	if old_layers.is_empty():
		cell_splats.erase(old_cell)
	else:
		cell_splats[old_cell] = old_layers
	splat_cells.erase(splat_id)

func _find_blood_surface(world_position: Vector3) -> Dictionary:
	if not is_inside_tree():
		return {}
	var from := world_position + Vector3.UP * 2.0
	var to := world_position + Vector3.DOWN * 4.0
	var excluded: Array[RID] = []
	for _attempt in range(4):
		var query := PhysicsRayQueryParameters3D.create(
			from,
			to,
			surface_collision_mask,
			excluded
		)
		var result := get_world_3d().direct_space_state.intersect_ray(query)
		if result.is_empty():
			return {}
		var collider := result.get("collider") as CollisionObject3D
		if collider != null and collider.is_in_group(&"blood_surface"):
			return result
		if collider == null:
			return {}
		excluded.append(collider.get_rid())
	return {}
