extends CharacterBody3D
class_name ZombieTarget

## 纯表现节点。不持有血量、不 _physics_process、不 move_and_slide、
## 不参与寻路、不参与命中判定。位置与朝向由 ZombieRenderer 每渲染帧
## 从 SimWorld 插值后写入。
##
## 根节点的碰撞体只在物理层 4 (ZombieBlocker)，collision_mask 为 0：
## 它唯一的作用是阻挡玩家的 move_and_slide()，不参与僵尸自身移动、
## 不参与导航、不参与射击判定，因此不引入任何不确定性。
const ZombieBehaviorMathScript = preload("res://scripts/combat/zombie_behavior_math.gd")

signal death_finished(view: ZombieTarget)

const HIT_REACTION_SECONDS := 0.2
const ATTACK_ANIMATION_SECONDS := 0.7
const DEATH_LINGER_SECONDS := 1.2
const RUN_ANIMATION_SPEED := 0.2

const AMBIENT_SOUNDS := [
	preload("res://assets/sfx/boxhead/zombie_ambience_1.mp3"),
	preload("res://assets/sfx/boxhead/zombie_ambience_2.mp3"),
	preload("res://assets/sfx/boxhead/zombie_ambience_3.mp3"),
	preload("res://assets/sfx/boxhead/zombie_ambience_4.mp3"),
]
const HIT_SOUND := preload("res://assets/sfx/boxhead/zombie_hit.mp3")
const HIT_AUDIO_COOLDOWN_SECONDS := 0.12

@export var reaction_spring: float = 18.0
@export var reaction_damping: float = 8.0
@export var max_visual_tilt_degrees: float = 18.0

@onready var visual_root: Node3D = $VisualRoot
@onready var blocker_collision: CollisionShape3D = $BlockerCollision
@onready var health_label: Label3D = $HealthLabel
@onready var voice_audio: AudioStreamPlayer3D = get_node_or_null("VoiceAudio")
@onready var attack_audio: AudioStreamPlayer3D = get_node_or_null("AttackAudio")
@onready var death_audio: AudioStreamPlayer3D = get_node_or_null("DeathAudio")

var animation_player: AnimationPlayer
var mesh_instances: Array[MeshInstance3D] = []
var initialized := false
var visual_rest_rotation := Vector3.ZERO
var reaction_rotation := Vector3.ZERO
var reaction_angular_velocity := Vector3.ZERO
var bound_zombie_id := 0
var hit_reaction_remaining := 0.0
var attack_animation_remaining := 0.0
var death_remaining := 0.0
var dying := false
## 音效随机是纯表现，不进模拟层：它不改变任何判定，各端听到的音高不同
## 也不会让任何一颗子弹打到不同的地方。
var audio_rng := RandomNumberGenerator.new()
var ambient_audio_remaining := 0.0
var hit_audio_cooldown := 0.0

func _ready() -> void:
	_ensure_initialized()

func _ensure_initialized() -> void:
	if initialized:
		return
	# project.godot 开着 common/physics_interpolation=true。本节点的 transform 由
	# ZombieRenderer 在 _process() 里每渲染帧写入（已经用 SimWorld 的上一/当前 tick
	# 插值过），若再交给引擎插值，引擎会把每次写入当成新的物理 tick 变换并从上一次
	# 变换插过去，近景模型会整体滞后一帧、与远景 MultiMesh 实例（set_instance_transform()
	# 绕过节点插值，落在精确插值位置）错位，正是 Step 15 人工验收要排除的「衔接处跳变」；
	# ZombieBlocker 碰撞体同样滞后，玩家阻挡感与看到的模型对不上。
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	if visual_root == null:
		visual_root = get_node("VisualRoot") as Node3D
	if blocker_collision == null:
		blocker_collision = get_node("BlockerCollision") as CollisionShape3D
	if health_label == null:
		health_label = get_node("HealthLabel") as Label3D
	animation_player = visual_root.find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	if animation_player != null:
		animation_player.animation_finished.connect(_on_animation_finished)
		animation_player.play(&"Idle")
	for candidate in visual_root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := candidate as MeshInstance3D
		if mesh_instance != null:
			mesh_instances.append(mesh_instance)
	visual_rest_rotation = visual_root.rotation
	audio_rng.randomize()
	ambient_audio_remaining = audio_rng.randf_range(2.0, 8.0)
	initialized = true

func bind_zombie(
	zombie_id_value: int,
	world_position: Vector3,
	facing_yaw: float
) -> void:
	_ensure_initialized()
	bound_zombie_id = zombie_id_value
	dying = false
	death_remaining = 0.0
	hit_reaction_remaining = 0.0
	attack_animation_remaining = 0.0
	reaction_rotation = Vector3.ZERO
	reaction_angular_velocity = Vector3.ZERO
	visual_root.rotation = visual_rest_rotation
	visual_root.scale = Vector3.ONE
	global_position = world_position
	rotation.y = facing_yaw
	visible = true
	set_blocker_enabled(true)
	# 视图是池化复用的：不停掉上一具尸体的声音，死亡音会盖在刚生成的僵尸身上。
	_reset_audio()
	if animation_player != null:
		animation_player.play(&"Idle", 0.05)

func _reset_audio() -> void:
	hit_audio_cooldown = 0.0
	ambient_audio_remaining = audio_rng.randf_range(2.0, 8.0)
	if voice_audio != null:
		voice_audio.stop()
	if attack_audio != null:
		attack_audio.stop()
	if death_audio != null:
		death_audio.stop()

func get_bound_zombie_id() -> int:
	return bound_zombie_id

## 每渲染帧由 ZombieRenderer 调用，参数已完成上一 tick 与当前 tick 的插值。
func apply_snapshot(
	world_position: Vector3,
	facing_yaw: float,
	planar_speed: float,
	behavior_state: int
) -> void:
	if dying:
		return
	global_position = world_position
	rotation.y = facing_yaw
	if animation_player == null:
		return
	if hit_reaction_remaining > 0.0 or attack_animation_remaining > 0.0:
		return
	var animation_name := &"Idle"
	if behavior_state != ZombieBehaviorMathScript.State.ATTACK and planar_speed > RUN_ANIMATION_SPEED:
		animation_name = &"Walk"
	if animation_player.current_animation != animation_name:
		animation_player.play(animation_name, 0.12)

func play_hit_reaction(hit_position: Vector3, impulse: Vector3) -> void:
	_ensure_initialized()
	if dying:
		return
	visual_root.scale = Vector3.ONE * 1.08
	var local_hit := hit_position - global_position
	var local_impulse := global_basis.inverse() * impulse
	var torque := local_hit.cross(local_impulse) * 0.075
	reaction_angular_velocity += Vector3(torque.x, 0.0, torque.z)
	_play_hit_sound()
	if animation_player != null and animation_player.has_animation(&"HitReact"):
		animation_player.play(&"HitReact", 0.05)
		hit_reaction_remaining = HIT_REACTION_SECONDS
		attack_animation_remaining = 0.0

func play_attack_windup() -> void:
	_ensure_initialized()
	if dying:
		return
	if attack_audio != null:
		attack_audio.play()
	if animation_player != null and animation_player.has_animation(&"Punch"):
		animation_player.play(&"Punch", 0.08)
		attack_animation_remaining = ATTACK_ANIMATION_SECONDS

func begin_death() -> void:
	_ensure_initialized()
	if dying:
		return
	dying = true
	death_remaining = DEATH_LINGER_SECONDS
	set_blocker_enabled(false)
	health_label.visible = false
	if voice_audio != null:
		voice_audio.stop()
	if attack_audio != null:
		attack_audio.stop()
	if death_audio != null:
		death_audio.play()
	if animation_player != null and animation_player.has_animation(&"Death"):
		animation_player.play(&"Death", 0.08)
		death_remaining = minf(
			animation_player.get_animation(&"Death").length,
			DEATH_LINGER_SECONDS
		)
	# 视图被回收时声音也跟着停，所以留场时间至少要盖住死亡音的长度，
	# 否则每一次击杀的音效都会被自己的尸体消失掐掉半句。
	if death_audio != null and death_audio.stream != null:
		death_remaining = maxf(death_remaining, death_audio.stream.get_length())

func is_dying() -> bool:
	return dying

func set_blocker_enabled(value: bool) -> void:
	_ensure_initialized()
	blocker_collision.disabled = not value

## LOD 切换时的淡入。GeometryInstance3D.transparency 由引擎切到透明管线，
## 不需要复制材质。
func set_visual_alpha(value: float) -> void:
	_ensure_initialized()
	var transparency := clampf(1.0 - value, 0.0, 1.0)
	for mesh_instance in mesh_instances:
		mesh_instance.transparency = transparency

func set_health_text(current_points: int, maximum_points: int) -> void:
	_ensure_initialized()
	if dying:
		return
	health_label.visible = true
	health_label.text = "%d / %d" % [
		ceili(float(current_points) / 100.0),
		ceili(float(maximum_points) / 100.0),
	]

func _process(delta: float) -> void:
	if not initialized:
		return
	hit_reaction_remaining = maxf(hit_reaction_remaining - delta, 0.0)
	attack_animation_remaining = maxf(attack_animation_remaining - delta, 0.0)
	hit_audio_cooldown = maxf(hit_audio_cooldown - delta, 0.0)
	_update_ambient_audio(delta)
	visual_root.scale = visual_root.scale.move_toward(Vector3.ONE, delta * 1.5)
	_update_visual_reaction(delta)
	if not dying:
		return
	death_remaining = maxf(death_remaining - delta, 0.0)
	if death_remaining > 0.0:
		return
	dying = false
	bound_zombie_id = 0
	visible = false
	death_finished.emit(self)

func _update_visual_reaction(delta: float) -> void:
	reaction_angular_velocity -= reaction_rotation * reaction_spring * delta
	reaction_angular_velocity = reaction_angular_velocity.move_toward(
		Vector3.ZERO,
		reaction_damping * delta
	)
	reaction_rotation += reaction_angular_velocity * delta
	var max_tilt := deg_to_rad(max_visual_tilt_degrees)
	if reaction_rotation.length() > max_tilt:
		reaction_rotation = reaction_rotation.normalized() * max_tilt
	visual_root.rotation = visual_rest_rotation + reaction_rotation

func _on_animation_finished(animation_name: StringName) -> void:
	if animation_name == &"HitReact":
		hit_reaction_remaining = 0.0
	elif animation_name == &"Punch":
		attack_animation_remaining = 0.0

## 中弹声。冷却是为了让穿透的一枪不至于在同一帧里把整排僵尸的受击声叠成爆音。
func _play_hit_sound() -> void:
	if voice_audio == null or hit_audio_cooldown > 0.0:
		return
	voice_audio.stop()
	voice_audio.stream = HIT_SOUND
	voice_audio.pitch_scale = audio_rng.randf_range(0.96, 1.04)
	voice_audio.play()
	hit_audio_cooldown = HIT_AUDIO_COOLDOWN_SECONDS

func _update_ambient_audio(delta: float) -> void:
	if dying or voice_audio == null:
		return
	ambient_audio_remaining -= delta
	if ambient_audio_remaining > 0.0:
		return
	ambient_audio_remaining = audio_rng.randf_range(8.0, 18.0)
	if voice_audio.playing:
		return
	voice_audio.stream = AMBIENT_SOUNDS[
		audio_rng.randi_range(0, AMBIENT_SOUNDS.size() - 1)
	]
	voice_audio.pitch_scale = audio_rng.randf_range(0.96, 1.04)
	voice_audio.play()
