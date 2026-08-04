extends Node3D
class_name GroundBloodManager

const SPLAT_SCENE := preload("res://scenes/fx/GroundBloodSplat.tscn")

@export_range(1, 512, 1) var max_splats := 192
@export_flags_3d_physics var surface_collision_mask := 1
@export_range(0.0, 1.0, 0.05) var hit_splat_probability := 0.55

var splats: Array[GroundBloodSplat] = []
var reuse_cursor := 0

func place_splat(
	surface_position: Vector3,
	surface_normal: Vector3,
	diameter: float,
	rotation_radians: float,
	tint: Color
) -> GroundBloodSplat:
	var splat := _acquire_splat()
	splat.setup(
		surface_position,
		surface_normal,
		diameter,
		rotation_radians,
		tint
	)
	return splat

func spawn_hit_splat(
	hit_position: Vector3,
	shot_direction: Vector3,
	intensity: float = 1.0
) -> GroundBloodSplat:
	if randf() > hit_splat_probability:
		return null
	var planar := Vector3(shot_direction.x, 0.0, shot_direction.z)
	if planar.length_squared() <= 0.000001:
		planar = Vector3.FORWARD
	else:
		planar = planar.normalized()
	var projected := hit_position + planar * randf_range(0.35, 0.9)
	var surface := _find_blood_surface(projected)
	if surface.is_empty():
		return null
	return place_splat(
		surface["position"],
		surface["normal"],
		randf_range(0.22, 0.45) * clampf(intensity, 0.75, 1.35),
		randf_range(-PI, PI),
		Color(0.42, 0.008, 0.015, randf_range(0.86, 0.96))
	)

func spawn_death_pool(
	world_position: Vector3,
	intensity: float = 1.0
) -> GroundBloodSplat:
	var surface := _find_blood_surface(world_position)
	if surface.is_empty():
		return null
	return place_splat(
		surface["position"],
		surface["normal"],
		randf_range(0.9, 1.4) * clampf(intensity, 0.8, 1.35),
		randf_range(-PI, PI),
		Color(0.36, 0.004, 0.01, 0.95)
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
