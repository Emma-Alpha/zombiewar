extends Node3D
class_name GroundBloodManager

enum BloodRequestType {
	HIT,
	TRAIL,
	DEATH_POOL,
}

const SPLAT_SCENE := preload("res://scenes/fx/GroundBloodSplat.tscn")
const BLOOD_IMPACT_SCENE := preload("res://scenes/fx/BloodImpact.tscn")
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
## 每帧落地的血迹数量。每次落地要做一次向下射线找地面，所以这是帧预算而不是
## 「越大越好」；但它必须跟得上武器射速与同屏僵尸数，否则请求会持续积压。
@export_range(1, 16, 1) var max_requests_per_frame := 6
## 待处理队列的上限。超出时丢弃**最旧**的请求。
##
## 血迹的价值随时间衰减：一发子弹的血迹迟几帧才落地，落的仍是当时的命中点，
## 而玩家那时往往已经转身或走开，看起来就是「明明打的是前面的僵尸，血却出现在
## 身后」。宁可不画，也不要画在一个已经解释不通的位置上。
@export_range(1, 128, 1) var max_pending_requests := 18
@export_range(1, 64, 1) var impact_pool_size := 24

var splats: Array[GroundBloodSplat] = []
var reuse_cursor := 0
var cell_splats: Dictionary = {}
var splat_cells: Dictionary = {}
var pending_requests: Array[Dictionary] = []
var impact_pool: Array[BloodImpact] = []
var impact_reuse_cursor := 0

func _ready() -> void:
	_ensure_impact_pool()
	set_process(not pending_requests.is_empty())

func spawn_blood_impact(
	hit_position: Vector3,
	shot_direction: Vector3,
	intensity: float = 1.0
) -> BloodImpact:
	_ensure_impact_pool()
	if impact_pool.is_empty():
		return null
	var impact := impact_pool[impact_reuse_cursor]
	impact_reuse_cursor = (impact_reuse_cursor + 1) % impact_pool.size()
	impact.setup(hit_position, shot_direction, intensity)
	return impact

func get_impact_pool_count() -> int:
	return impact_pool.size()

func _ensure_impact_pool() -> void:
	var resolved_pool_size := maxi(impact_pool_size, 1)
	while impact_pool.size() < resolved_pool_size:
		var impact := BLOOD_IMPACT_SCENE.instantiate() as BloodImpact
		add_child(impact)
		impact.set_pooled(true)
		impact_pool.append(impact)

func _process(_delta: float) -> void:
	var request_count := mini(
		pending_requests.size(),
		maxi(max_requests_per_frame, 1)
	)
	for _request_index in range(request_count):
		_process_blood_request(pending_requests.pop_front())
	if pending_requests.is_empty():
		set_process(false)

func queue_hit_splat(
	hit_position: Vector3,
	shot_direction: Vector3,
	intensity: float = 1.0
) -> void:
	_queue_blood_request({
		"type": BloodRequestType.HIT,
		"position": hit_position,
		"direction": shot_direction,
		"intensity": intensity,
	})

func queue_trail_splat(
	world_position: Vector3,
	move_direction: Vector3,
	intensity: float,
	progress: float
) -> void:
	_queue_blood_request({
		"type": BloodRequestType.TRAIL,
		"position": world_position,
		"direction": move_direction,
		"intensity": intensity,
		"progress": progress,
	})

func queue_death_pool(
	world_position: Vector3,
	intensity: float = 1.0
) -> void:
	_queue_blood_request({
		"type": BloodRequestType.DEATH_POOL,
		"position": world_position,
		"intensity": intensity,
	})

func get_pending_request_count() -> int:
	return pending_requests.size()

func _queue_blood_request(request: Dictionary) -> void:
	pending_requests.append(request)
	# 积压时丢最旧的：迟到的血迹会落在玩家已经离开的位置上（见 max_pending_requests）。
	var limit := maxi(max_pending_requests, 1)
	while pending_requests.size() > limit:
		pending_requests.pop_front()
	set_process(true)

func _process_blood_request(request: Dictionary) -> void:
	match int(request["type"]):
		BloodRequestType.HIT:
			spawn_hit_splat(
				request["position"],
				request["direction"],
				request["intensity"]
			)
		BloodRequestType.TRAIL:
			spawn_trail_splat(
				request["position"],
				request["direction"],
				request["intensity"],
				request["progress"]
			)
		BloodRequestType.DEATH_POOL:
			spawn_death_pool(request["position"], request["intensity"])

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
		var merged := _size_matched_layer(existing_layers, size)
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
	var horizontal_direction := Vector3(shot_direction.x, 0.0, shot_direction.z)
	var rotation_radians := 0.0
	if horizontal_direction.length_squared() > 0.000001:
		rotation_radians = atan2(horizontal_direction.x, horizontal_direction.z)
	rotation_radians += randf_range(-0.12, 0.12)
	return place_splat(
		surface["position"],
		surface["normal"],
		Vector2.ONE * diameter,
		rotation_radians,
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
	var width := lerpf(0.45, 0.28, resolved_progress)
	var length := lerpf(0.8, 0.5, resolved_progress)
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
		clampf(randf_range(1.15, 1.4) * resolved_intensity, 1.15, 1.4),
		clampf(randf_range(1.15, 1.4) * resolved_intensity, 1.15, 1.4)
	)
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

func _size_matched_layer(
	existing_layers: Array,
	requested_size: Vector2
) -> GroundBloodSplat:
	var matched := existing_layers[0] as GroundBloodSplat
	var smallest_difference := INF
	for layer in existing_layers:
		var splat := layer as GroundBloodSplat
		var layer_size := splat.base_size
		var difference := absf(layer_size.x - requested_size.x) + absf(
			layer_size.y - requested_size.y
		)
		if difference < smallest_difference:
			smallest_difference = difference
			matched = splat
	return matched

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
