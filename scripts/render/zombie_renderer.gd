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

var camera_anchor: Node3D
var zombie_scenes: Array[PackedScene] = []
var type_buckets: Array[Dictionary] = []
var near_views: Dictionary = {}
var near_view_profile: Dictionary = {}
var dying_view_records: Dictionary = {}
var view_alpha: Dictionary = {}
var total_near_view_count := 0
var allocated_near_views: Array[ZombieTarget] = []
var lod_scratch: Array = []

func configure_zombie_scenes(value: Array[PackedScene]) -> void:
	if not type_buckets.is_empty():
		_discard_render_resources()
	zombie_scenes.clear()
	zombie_scenes.append_array(value)
	if camera_anchor != null:
		_create_type_buckets()

func setup(anchor: Node3D) -> void:
	camera_anchor = anchor
	if type_buckets.is_empty():
		_create_type_buckets()
	# project.godot 开着 common/physics_interpolation=true；本渲染器已经在
	# render_frame() 里自己做完了 tick 间插值，必须关掉引擎插值，
	# 否则近景 ZombieTarget 与远景实例会错开一帧。
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

func clear() -> void:
	for zombie_id_value in near_views.keys():
		_release_view(zombie_id_value, near_views[zombie_id_value])
	for record in dying_view_records.values():
		var view := record["view"] as ZombieTarget
		if view == null or not is_instance_valid(view):
			continue
		# clear() 中断死亡表现，避免 setup 重入后仍有旧动画在池外占用名额。
		view.bind_zombie(0, Vector3.ZERO, 0.0)
		_release_view_to_profile(view, int(record["profile_index"]))
	near_views = {}
	near_view_profile = {}
	dying_view_records = {}
	view_alpha = {}
	for bucket in type_buckets:
		var multi_mesh := bucket["multi_mesh"] as MultiMesh
		if multi_mesh != null:
			multi_mesh.visible_instance_count = 0

## 把顿帧状态广播给当前所有近景视图，包括正在播死亡动画的那些。
##
## 每帧无条件调用，而不是只在冻结状态翻转的那一帧调用：LOD 归属每 tick 都在换人，
## 顿帧期间新进入近景的视图必须立刻跟上，否则同一画面里会有一部分僵尸还在动。
## 远景 MultiMesh 不需要单独处理——顿帧期间 render_frame() 整个不跑，
## 它自然停在上一帧的实例变换上。
func set_visual_frozen(frozen: bool) -> void:
	for view in near_views.values():
		var near_view := view as ZombieTarget
		if near_view != null and is_instance_valid(near_view):
			near_view.set_visual_frozen(frozen)
	for record in dying_view_records.values():
		var dying_view := record["view"] as ZombieTarget
		if dying_view != null and is_instance_valid(dying_view):
			dying_view.set_visual_frozen(frozen)

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
		var index: int = wanted[zombie_id_value]
		var profile_index := world.get_zombie_profile_index(index)
		var view := _acquire_view(profile_index)
		if view == null:
			continue
		view.bind_zombie(
			zombie_id_value,
			_world_origin(world, index, 1.0),
			world.get_zombie_facing(index)
		)
		view.set_visual_alpha(0.0)
		near_views[zombie_id_value] = view
		near_view_profile[zombie_id_value] = profile_index
		view_alpha[zombie_id_value] = 0.0

## 渲染帧之间对 SimWorld 的上一 tick 与当前 tick 做线性插值。
func render_frame(
	world: SimWorld,
	interpolation_alpha: float,
	frame_delta: float
) -> void:
	if type_buckets.is_empty():
		return
	var count := world.get_zombie_count()
	for bucket_index in range(type_buckets.size()):
		var bucket := type_buckets[bucket_index]
		var multi_mesh := bucket["multi_mesh"] as MultiMesh
		if multi_mesh != null and multi_mesh.instance_count < count:
			multi_mesh.instance_count = maxi(count, MULTI_MESH_MINIMUM_CAPACITY)
		bucket["far_slot"] = 0
		type_buckets[bucket_index] = bucket
	var ids := world.get_zombie_id_array()
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
		var profile_index := world.get_zombie_profile_index(index)
		if profile_index < 0 or profile_index >= type_buckets.size():
			continue
		var bucket := type_buckets[profile_index]
		var multi_mesh := bucket["multi_mesh"] as MultiMesh
		if multi_mesh == null:
			continue
		var far_slot: int = bucket["far_slot"]
		multi_mesh.set_instance_transform(
			far_slot,
			Transform3D(Basis(Vector3.UP, facing), origin)
		)
		bucket["far_slot"] = far_slot + 1
		type_buckets[profile_index] = bucket
	for bucket in type_buckets:
		var multi_mesh := bucket["multi_mesh"] as MultiMesh
		if multi_mesh != null:
			multi_mesh.visible_instance_count = int(bucket["far_slot"])

## 本 tick 死亡的僵尸：近景表现件脱离池子播放死亡动画，播完自行归还。
func notify_deaths(world: SimWorld) -> void:
	for zombie_id_value in world.tick_death_events:
		if not near_views.has(zombie_id_value):
			continue
		var view: ZombieTarget = near_views[zombie_id_value]
		var profile_index: int = near_view_profile.get(zombie_id_value, -1)
		near_views.erase(zombie_id_value)
		near_view_profile.erase(zombie_id_value)
		view_alpha.erase(zombie_id_value)
		dying_view_records[view.get_instance_id()] = {
			"view": view,
			"profile_index": profile_index,
		}
		view.begin_death()

func get_near_view(zombie_id_value: int) -> ZombieTarget:
	return near_views.get(zombie_id_value, null) as ZombieTarget

func get_type_bucket_count() -> int:
	return type_buckets.size()

func get_near_view_profile(zombie_id_value: int) -> int:
	return int(near_view_profile.get(zombie_id_value, -1))

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

func _acquire_view(profile_index: int) -> ZombieTarget:
	if profile_index < 0 or profile_index >= type_buckets.size():
		return null
	var bucket := type_buckets[profile_index]
	var free_views: Array = bucket["free_views"]
	var view: ZombieTarget = null
	if not free_views.is_empty():
		view = free_views.pop_back() as ZombieTarget
	elif total_near_view_count < NEAR_LOD_COUNT:
		var scene := bucket["scene"] as PackedScene
		if scene == null:
			return null
		view = scene.instantiate() as ZombieTarget
		if view == null:
			return null
		view.name = "ZombieView%02d" % total_near_view_count
		add_child(view)
		view.death_finished.connect(_on_view_death_finished)
		total_near_view_count += 1
		allocated_near_views.append(view)
	else:
		view = _take_idle_view_from_other_profile(profile_index)
		if view == null:
			return null
	view.visible = true
	view.set_blocker_enabled(true)
	return view

## 全局名额已满时，其他 profile 的 idle View 不能把本 profile 永久饿死。
## death View 不在 free list，因此不会在动画中途被换走；不同场景则保持
## total_near_view_count 不变，用目标场景实例原位替换空闲实例。
func _take_idle_view_from_other_profile(profile_index: int) -> ZombieTarget:
	var target_scene := type_buckets[profile_index]["scene"] as PackedScene
	if target_scene == null:
		return null
	for donor_profile_index in range(type_buckets.size()):
		if donor_profile_index == profile_index:
			continue
		var donor_bucket := type_buckets[donor_profile_index]
		var free_views: Array = donor_bucket["free_views"]
		if free_views.is_empty():
			continue
		var idle_view := free_views.pop_back() as ZombieTarget
		if idle_view == null or not is_instance_valid(idle_view):
			continue
		var donor_scene := donor_bucket["scene"] as PackedScene
		if donor_scene == target_scene:
			return idle_view
		var replacement_instance := target_scene.instantiate()
		var replacement := replacement_instance as ZombieTarget
		if replacement == null:
			if replacement_instance != null:
				replacement_instance.free()
			free_views.append(idle_view)
			continue
		var recycled_name := idle_view.name
		allocated_near_views.erase(idle_view)
		idle_view.free()
		replacement.name = recycled_name
		add_child(replacement)
		replacement.death_finished.connect(_on_view_death_finished)
		allocated_near_views.append(replacement)
		return replacement
	return null

func _release_view(zombie_id_value: int, view: ZombieTarget) -> void:
	var profile_index: int = near_view_profile.get(zombie_id_value, -1)
	near_view_profile.erase(zombie_id_value)
	_release_view_to_profile(view, profile_index)

func _release_view_to_profile(view: ZombieTarget, profile_index: int) -> void:
	view.visible = false
	view.set_blocker_enabled(false)
	view.set_visual_alpha(1.0)
	if profile_index >= 0 and profile_index < type_buckets.size():
		var bucket := type_buckets[profile_index]
		var free_views: Array = bucket["free_views"]
		if not free_views.has(view):
			free_views.append(view)

func _on_view_death_finished(view: ZombieTarget) -> void:
	var view_instance_id := view.get_instance_id()
	if not dying_view_records.has(view_instance_id):
		return
	var record: Dictionary = dying_view_records[view_instance_id]
	dying_view_records.erase(view_instance_id)
	_release_view_to_profile(view, int(record["profile_index"]))

func _discard_render_resources() -> void:
	for view in allocated_near_views:
		if is_instance_valid(view):
			view.queue_free()
	allocated_near_views = []
	for bucket in type_buckets:
		var multi_mesh_instance := bucket["multi_mesh_instance"] as MultiMeshInstance3D
		if multi_mesh_instance != null and is_instance_valid(multi_mesh_instance):
			multi_mesh_instance.queue_free()
	type_buckets = []
	near_views = {}
	near_view_profile = {}
	dying_view_records = {}
	view_alpha = {}
	total_near_view_count = 0

func _create_type_buckets() -> void:
	for scene in zombie_scenes:
		type_buckets.append(_create_type_bucket(scene))

## 远景使用僵尸模型的绑定姿势网格。MultiMesh 不驱动骨骼，
## 因此这里拿到的就是 spec 要求的静态姿势。
func _create_type_bucket(scene: PackedScene) -> Dictionary:
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.instance_count = MULTI_MESH_MINIMUM_CAPACITY
	multi_mesh.visible_instance_count = 0
	var far_lod_material: Material = null
	if scene != null:
		var probe := scene.instantiate()
		for candidate in probe.find_children("*", "MeshInstance3D", true, false):
			var mesh_instance := candidate as MeshInstance3D
			if mesh_instance == null or mesh_instance.mesh == null:
				continue
			multi_mesh.mesh = mesh_instance.mesh
			far_lod_material = mesh_instance.get_active_material(0)
			break
		probe.free()
	var multi_mesh_instance := MultiMeshInstance3D.new()
	multi_mesh_instance.name = "FarLodMultiMesh%02d" % type_buckets.size()
	multi_mesh_instance.multimesh = multi_mesh
	multi_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if far_lod_material != null:
		multi_mesh_instance.material_override = far_lod_material
	add_child(multi_mesh_instance)
	return {
		"scene": scene,
		"multi_mesh": multi_mesh,
		"multi_mesh_instance": multi_mesh_instance,
		"free_views": [],
		"far_slot": 0,
	}

static func _compare_lod(left: Array, right: Array) -> bool:
	var left_distance: float = left[0]
	var right_distance: float = right[0]
	if left_distance != right_distance:
		return left_distance < right_distance
	return int(left[1]) < int(right[1])
