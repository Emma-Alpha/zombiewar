extends Node3D
class_name LobbyPlayerPreview

const DISPLAY_WEAPON := "SMG"
const LEGACY_LONG_GUN_MODEL_NAME := "Ri" + "fle"
const WEAPON_NAMES := [
	"Axe",
	"Guitar",
	"Knife",
	"Pistol",
	LEGACY_LONG_GUN_MODEL_NAME,
	"Shotgun",
	"SMG",
	"Spear",
	"WoodenBat_Barbed",
	"WoodenBat_Saw",
]

@export var character_scene: PackedScene

var player_index := 0
var online := true
var accent_color := Color(1.0, 0.43, 0.24, 1.0)
var character_model: Node3D
var missing_resource_warned := false
var missing_animation_warned := false

func _ready() -> void:
	_instantiate_character()
	_apply_status()

func set_player_index(index: int) -> void:
	player_index = maxi(index, 0)
	_apply_status()

func set_online(value: bool) -> void:
	online = value
	_apply_status()

## 角色配色。落在灯光颜色与名牌描边上，不碰模型材质——
## 角色用的是单张 atlas，整体染色会把脸和武器一并染了。
func set_accent_color(value: Color) -> void:
	accent_color = value
	_apply_status()

## 座位卡里名字由卡片自己的 2D 标签画，Label3D 要能关掉，
## 否则同一个名字会在卡里出现两次。
func set_label_visible(value: bool) -> void:
	var label := get_node_or_null("PlayerLabel") as Label3D
	if label != null:
		label.visible = value

func _instantiate_character() -> void:
	if character_scene == null:
		_warn_missing_resource()
		return
	var instance := character_scene.instantiate() as Node3D
	if instance == null:
		_warn_missing_resource()
		return
	character_model = instance
	character_model.name = "CharacterModel"
	$ModelAnchor.add_child(character_model)
	_configure_weapons()
	_play_idle_animation()

func _configure_weapons() -> void:
	if character_model == null:
		return
	for weapon_name in WEAPON_NAMES:
		var weapon := character_model.find_child(weapon_name, true, false) as Node3D
		if weapon != null:
			weapon.visible = weapon_name == DISPLAY_WEAPON

func _play_idle_animation() -> void:
	var animation_player := character_model.find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	if animation_player == null or not animation_player.has_animation(&"Idle_Gun"):
		if not missing_animation_warned:
			push_warning("Lobby character preview is missing Idle_Gun animation")
			missing_animation_warned = true
		return
	animation_player.play(&"Idle_Gun", 0.15)

func _apply_status() -> void:
	var label := get_node_or_null("PlayerLabel") as Label3D
	if label != null:
		label.text = "P%d" % (player_index + 1)
		# modulate 表达在线/离线，outline_modulate 表达角色配色。
		# 两者分开，才能让「离线变暗」不把配色一起洗掉。
		label.modulate = Color.WHITE if online else Color(0.5, 0.53, 0.55, 1.0)
		label.outline_modulate = accent_color
	var light := get_node_or_null("PlayerLight") as OmniLight3D
	if light != null:
		light.light_color = accent_color
		light.light_energy = 1.25 if online else 0.28

func _warn_missing_resource() -> void:
	if missing_resource_warned:
		return
	push_warning("Lobby character preview could not instantiate its character scene")
	missing_resource_warned = true
