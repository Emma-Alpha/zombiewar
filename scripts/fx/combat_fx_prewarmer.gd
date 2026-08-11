extends Node3D
class_name CombatFxPrewarmer

const FxWarmupContextScript = preload("res://scripts/fx/fx_warmup_context.gd")
const DEFAULT_FX_ROOT := "res://scenes/fx"

## 音频预热只把这些 MP3 的解码与 voice 连接提前到开局做掉，
## 不改变任何一次真实播放的音量、音高或时序——纯表现，不进模拟层。
##
## 背景：Web 导出是单线程（variant/thread_support=false），渲染、MP3 解码、
## voice 连接全在主线程上。AudioStreamMP3 是懒解码的，preload() 只加载资源对象，
## 第一次 play() 才真正建立解码器并把 voice 接上总线——这一下同步开销在
## 「首次进房 + 第一枪」时正好落在已经繁忙的开局帧上，造成整帧卡顿。
## 视觉 shader 已由 prewarm() 用 force_draw/force_sync 预热，唯独音频路径没人管。
##
## 用 -60dB（接近静音）而不是音量 0 / stream_paused：只有真的走一遍 play()
## 才会触发解码与 voice 连接，静音或暂停都绕开了我们要预热的那条路径。
const AUDIO_WARMUP_VOLUME_DB := -60.0
const COMBAT_AUDIO_STREAMS: Array[AudioStream] = [
	preload("res://assets/sfx/boxhead/pistol_fire.mp3"),
	preload("res://assets/sfx/boxhead/smg_fire.mp3"),
	preload("res://assets/sfx/boxhead/bullet_wall_1.mp3"),
	preload("res://assets/sfx/boxhead/bullet_wall_2.mp3"),
	preload("res://assets/sfx/boxhead/bullet_wall_3.mp3"),
	preload("res://assets/sfx/boxhead/zombie_hit.mp3"),
	preload("res://assets/sfx/boxhead/zombie_attack.mp3"),
	preload("res://assets/sfx/boxhead/creature_fall.mp3"),
	preload("res://assets/sfx/boxhead/explosion.mp3"),
	preload("res://assets/sfx/boxhead/pickup.mp3"),
	preload("res://assets/sfx/boxhead/player_scream_1.mp3"),
	preload("res://assets/sfx/boxhead/player_scream_2.mp3"),
	preload("res://assets/sfx/boxhead/zombie_ambience_1.mp3"),
	preload("res://assets/sfx/boxhead/zombie_ambience_2.mp3"),
	preload("res://assets/sfx/boxhead/zombie_ambience_3.mp3"),
	preload("res://assets/sfx/boxhead/zombie_ambience_4.mp3"),
]

## ZombieTarget 视图在 ZombieRenderer._ready() 里就实例化了，但 visible=false——
## 它们的骨骼网格 surface 要等到第一只僵尸刷到近景才真正提交绘制，
## 在 WebGL/gl_compatibility 上单线程懒编译蒙皮管线，正是「开局第一波/开枪」
## 那一下掉帧的另一个来源。这里借开局预热把一个近景视图和一帧远景
## MultiMesh 真的画一遍，把蒙皮与 MultiMesh 两条管线都提前编译掉。
const ZOMBIE_TARGET_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")

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
	_warmup_zombie_renderer(context)
	RenderingServer.force_draw(false, 0.0)
	RenderingServer.force_sync()
	for effect in active_effects:
		if not is_instance_valid(effect):
			continue
		effect.call("finish_render_warmup")
	host.free()
	_prewarm_audio()

## 在开局把战斗相关的每条 MP3 都以近静音各播一遍，强制浏览器/引擎
## 提前完成懒解码与 voice 连接，避免「首次进房 + 第一枪」时这条路径
## 在单线程主循环上造成整帧卡顿。
##
## 逐条 play() 再统一 stop()，而不是「播一条停一条」：后者可能把解码/连接
## 又退回懒加载。每个流各占一个临时 voice，-60dB 下叠加也听不出来。
##
## 时机上这里安全：本函数在玩家已进入房间、且开局手势已经解开了
## Web 音频自动播放限制之后才跑（见 _run_combat_startup）。
func _prewarm_audio() -> void:
	var warmup_players: Array[AudioStreamPlayer] = []
	for stream in COMBAT_AUDIO_STREAMS:
		if stream == null:
			continue
		var player := AudioStreamPlayer.new()
		player.stream = stream
		player.volume_db = AUDIO_WARMUP_VOLUME_DB
		add_child(player)
		player.play()
		warmup_players.append(player)
	for player in warmup_players:
		player.stop()
		player.queue_free()

## 把一个 ZombieTarget 近景视图与一帧远景 MultiMesh 摆进视野、临时设为可见，
## 让紧随其后的 force_draw() 把蒙皮管线与 MultiMesh 管线都编译掉。
## 近景与远景共享同一份网格/材质（见 ZombieRenderer._extract_far_lod_mesh），
## 所以各画一份即可覆盖所有僵尸 surface。二者都挂进 warmup host，
## 随 host.free() 一并释放，不进对象池、不影响模拟层。
func _warmup_zombie_renderer(context: FxWarmupContext) -> void:
	var view_position := context.position_in_view(3.0)
	var near_view := ZOMBIE_TARGET_SCENE.instantiate() as ZombieTarget
	if near_view != null:
		context.host.add_child(near_view)
		near_view.global_position = view_position
		near_view.visible = true
	var probe := ZOMBIE_TARGET_SCENE.instantiate()
	var far_mesh: Mesh = null
	var far_material: Material = null
	for candidate in probe.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := candidate as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		far_mesh = mesh_instance.mesh
		far_material = mesh_instance.get_active_material(0)
		break
	probe.free()
	if far_mesh == null:
		return
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.mesh = far_mesh
	multi_mesh.instance_count = 1
	multi_mesh.visible_instance_count = 1
	multi_mesh.set_instance_transform(0, Transform3D(Basis(), view_position))
	var multi_mesh_instance := MultiMeshInstance3D.new()
	multi_mesh_instance.multimesh = multi_mesh
	multi_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if far_material != null:
		multi_mesh_instance.material_override = far_material
	context.host.add_child(multi_mesh_instance)

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
