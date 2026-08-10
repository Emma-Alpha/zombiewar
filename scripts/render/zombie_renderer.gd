extends Node3D
class_name ZombieRenderer

## MultiMesh 不支持骨骼动画，而现有僵尸是 GLTF + AnimationPlayer，
## 因此采用距离 LOD 混合：距共享镜头中心最近的 NEAR_LOD_COUNT 只实例化
## 现有 ZombieTarget 场景（仅作表现），其余走 MultiMeshInstance3D 静态姿势。
##
## LOD 归属不进入模拟层：它是纯表现决策，允许各客户端不同。
const SimClockScript = preload("res://scripts/sim/sim_clock.gd")

const NEAR_LOD_COUNT := 48
## 玩家活动区半宽 11.2 / 半深 9.7（PlayerScreenBounds.ONLINE_BOUNDS_*），
## 取对角线（≈14.8）加一个僵尸半径作为「必须提供阻挡体」的半径。
## 近景名额按半径准入而不是无条件取最近 N 只：只按数量取时，
## 波次超过 NEAR_LOD_COUNT 后紧挨玩家的僵尸也可能落选而失去阻挡体，
## 玩家会直接穿过去。半径内僵尸数超过 NEAR_LOD_COUNT 时仍会有漏网的，
## 这是已记录在 Global Constraints 里的已知收窄。
const BLOCKER_RADIUS := 15.0
const FADE_SECONDS := 0.18
const MULTI_MESH_MINIMUM_CAPACITY := 64
const RUN_ANIMATION_SPEED := 0.2

@export var zombie_scene: PackedScene

var camera_anchor: Node3D
var multi_mesh_instance: MultiMeshInstance3D
var multi_mesh: MultiMesh
var far_lod_material: Material
var near_views: Dictionary = {}
var view_alpha: Dictionary = {}
var free_views: Array[ZombieTarget] = []
var lod_scratch: Array = []

func setup(anchor: Node3D) -> void:
	camera_anchor = anchor
	if multi_mesh_instance == null:
		multi_mesh = MultiMesh.new()
		multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
		multi_mesh.mesh = _extract_far_lod_mesh()
		multi_mesh.instance_count = MULTI_MESH_MINIMUM_CAPACITY
		multi_mesh.visible_instance_count = 0
		multi_mesh_instance = MultiMeshInstance3D.new()
		multi_mesh_instance.name = "FarLodMultiMesh"
		multi_mesh_instance.multimesh = multi_mesh
		multi_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if far_lod_material != null:
			multi_mesh_instance.material_override = far_lod_material
		add_child(multi_mesh_instance)
		# project.godot 开着 common/physics_interpolation=true；本渲染器已经在
		# render_frame() 里自己做完了 tick 间插值，必须关掉引擎插值，
		# 否则近景 ZombieTarget 与远景实例会错开一帧。
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	while free_views.size() + near_views.size() < NEAR_LOD_COUNT:
		var view := zombie_scene.instantiate() as ZombieTarget
		view.name = "ZombieView%02d" % (free_views.size() + near_views.size())
		add_child(view)
		view.death_finished.connect(_on_view_death_finished)
		view.visible = false
		view.set_blocker_enabled(false)
		free_views.append(view)

func clear() -> void:
	for zombie_id_value in near_views.keys():
		_release_view(zombie_id_value, near_views[zombie_id_value])
	near_views = {}
	view_alpha = {}
	if multi_mesh != null:
		multi_mesh.visible_instance_count = 0

## 每 tick 重算 LOD 归属。距离取共享镜头锚点到僵尸的 XZ 平面平方距离，
## 同距按实体 id 升序决定，避免抖动。
## 准入条件是「在 BLOCKER_RADIUS 之内」且「名额未超过 NEAR_LOD_COUNT」，
## 二者都不满足的僵尸只出现在远景 MultiMesh 上，没有阻挡体。
func sync_lod(world: SimWorld) -> void:
	var anchor_position := (
		camera_anchor.global_position if camera_anchor != null else Vector3.ZERO
	)
	var anchor_xz := Vector2(anchor_position.x, anchor_position.z)
	var ids := world.get_zombie_id_array()
	lod_scratch.clear()
	for index in range(world.get_zombie_count()):
		lod_scratch.append([
			anchor_xz.distance_squared_to(world.get_zombie_position(index)),
			ids[index],
			index,
		])
	lod_scratch.sort_custom(_compare_lod)
	var wanted: Dictionary = {}
	var blocker_radius_squared := BLOCKER_RADIUS * BLOCKER_RADIUS
	for slot in range(lod_scratch.size()):
		if wanted.size() >= NEAR_LOD_COUNT:
			break
		# lod_scratch 已按距离升序，超出半径后面的只会更远，直接停。
		if float(lod_scratch[slot][0]) > blocker_radius_squared:
			break
		wanted[lod_scratch[slot][1]] = lod_scratch[slot][2]
	for zombie_id_value in near_views.keys():
		if wanted.has(zombie_id_value):
			continue
		var view: ZombieTarget = near_views[zombie_id_value]
		if view.is_dying():
			continue
		_release_view(zombie_id_value, view)
		near_views.erase(zombie_id_value)
		view_alpha.erase(zombie_id_value)
	for zombie_id_value in wanted.keys():
		if near_views.has(zombie_id_value):
			continue
		var view := _acquire_view()
		if view == null:
			break
		var index: int = wanted[zombie_id_value]
		view.bind_zombie(
			zombie_id_value,
			_world_origin(world, index, 1.0),
			world.get_zombie_facing(index)
		)
		view.set_visual_alpha(0.0)
		near_views[zombie_id_value] = view
		view_alpha[zombie_id_value] = 0.0

## 渲染帧之间对 SimWorld 的上一 tick 与当前 tick 做线性插值。
func render_frame(
	world: SimWorld,
	interpolation_alpha: float,
	frame_delta: float
) -> void:
	if multi_mesh == null:
		return
	var count := world.get_zombie_count()
	if multi_mesh.instance_count < count:
		multi_mesh.instance_count = maxi(count, MULTI_MESH_MINIMUM_CAPACITY)
	var ids := world.get_zombie_id_array()
	var far_slot := 0
	for index in range(count):
		var zombie_id_value := ids[index]
		var previous := world.get_zombie_previous_position(index)
		var current := world.get_zombie_position(index)
		var origin := _world_origin(world, index, interpolation_alpha)
		var facing := lerp_angle(
			world.get_zombie_previous_facing(index),
			world.get_zombie_facing(index),
			interpolation_alpha
		)
		if near_views.has(zombie_id_value):
			var view: ZombieTarget = near_views[zombie_id_value]
			var speed := previous.distance_to(current) / SimClockScript.TICK_SECONDS
			view.apply_snapshot(origin, facing, speed, world.get_zombie_state(index))
			view.set_health_text(
				world.get_zombie_health(index),
				world.get_zombie_max_health(index)
			)
			var current_alpha: float = view_alpha.get(zombie_id_value, 1.0)
			if current_alpha < 1.0:
				current_alpha = minf(current_alpha + frame_delta / FADE_SECONDS, 1.0)
				view_alpha[zombie_id_value] = current_alpha
				view.set_visual_alpha(current_alpha)
			continue
		multi_mesh.set_instance_transform(
			far_slot,
			Transform3D(Basis(Vector3.UP, facing), origin)
		)
		far_slot += 1
	multi_mesh.visible_instance_count = far_slot

## 本 tick 死亡的僵尸：近景表现件脱离池子播放死亡动画，播完自行归还。
func notify_deaths(world: SimWorld) -> void:
	for zombie_id_value in world.tick_death_events:
		if not near_views.has(zombie_id_value):
			continue
		var view: ZombieTarget = near_views[zombie_id_value]
		near_views.erase(zombie_id_value)
		view_alpha.erase(zombie_id_value)
		view.begin_death()

func get_near_view(zombie_id_value: int) -> ZombieTarget:
	return near_views.get(zombie_id_value, null) as ZombieTarget

func _world_origin(world: SimWorld, index: int, alpha: float) -> Vector3:
	var blended := world.get_zombie_previous_position(index).lerp(
		world.get_zombie_position(index), alpha
	)
	var height := lerpf(
		world.get_zombie_previous_height(index),
		world.get_zombie_height(index),
		alpha
	)
	return Vector3(blended.x, height, blended.y)

func _acquire_view() -> ZombieTarget:
	if free_views.is_empty():
		return null
	var view: ZombieTarget = free_views.pop_back()
	view.visible = true
	view.set_blocker_enabled(true)
	return view

func _release_view(_zombie_id_value: int, view: ZombieTarget) -> void:
	view.visible = false
	view.set_blocker_enabled(false)
	view.set_visual_alpha(1.0)
	if not free_views.has(view):
		free_views.append(view)

func _on_view_death_finished(view: ZombieTarget) -> void:
	view.set_blocker_enabled(false)
	view.set_visual_alpha(1.0)
	if not free_views.has(view):
		free_views.append(view)

## 远景使用僵尸模型的绑定姿势网格。MultiMesh 不驱动骨骼，
## 因此这里拿到的就是 spec 要求的静态姿势。
func _extract_far_lod_mesh() -> Mesh:
	if zombie_scene == null:
		return null
	var probe := zombie_scene.instantiate()
	var resolved_mesh: Mesh = null
	for candidate in probe.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := candidate as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		resolved_mesh = mesh_instance.mesh
		far_lod_material = mesh_instance.get_active_material(0)
		break
	probe.free()
	return resolved_mesh

static func _compare_lod(left: Array, right: Array) -> bool:
	var left_distance: float = left[0]
	var right_distance: float = right[0]
	if left_distance != right_distance:
		return left_distance < right_distance
	return int(left[1]) < int(right[1])
