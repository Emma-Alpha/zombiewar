extends PanelContainer
class_name MapCard

## 房间左下角的地图卡。展示件加一个「我想换图」的意图信号——
## 到底能不能换由房间面板决定，卡片不自己判断谁是房主。

signal map_change_requested

const STAR_COUNT := 5
const STAR_LIT := Color(0.94, 0.32, 0.28, 1.0)
const STAR_DIM := Color(0.35, 0.37, 0.40, 0.35)
const NO_MAP_TEXT := "未选择地图"

@onready var thumbnail: TextureRect = %Thumbnail
@onready var thumbnail_placeholder: ColorRect = %ThumbnailPlaceholder
@onready var map_name_label: Label = %MapNameLabel
@onready var difficulty_row: HBoxContainer = %DifficultyRow
@onready var change_hint: Label = %ChangeHint
@onready var button: Button = %ClickArea

var editable := false

func _ready() -> void:
	button.pressed.connect(_on_pressed)

func set_map(definition: MapDefinition, is_editable: bool) -> void:
	editable = is_editable
	change_hint.visible = is_editable
	button.disabled = not is_editable
	if definition == null:
		map_name_label.text = NO_MAP_TEXT
		thumbnail.visible = false
		thumbnail_placeholder.visible = true
		_apply_difficulty(0)
		return
	map_name_label.text = definition.display_name
	# 真实缩略图要人进游戏俯视截图，缺它时画占位色块——
	# 一个空洞会被当成「这里坏了」，一块色块不会。
	var has_thumbnail := definition.thumbnail != null
	thumbnail.texture = definition.thumbnail
	thumbnail.visible = has_thumbnail
	thumbnail_placeholder.visible = not has_thumbnail
	_apply_difficulty(definition.difficulty)

## 难度用 ColorRect 小方块而不是「●」这类字形：字体子集里没有它，
## 而缺字形只在 Web 导出上现形——桌面端会被系统字体回退掩盖过去。
## 不用字形就不可能缺字形。
func _apply_difficulty(level: int) -> void:
	for index in range(difficulty_row.get_child_count()):
		var star := difficulty_row.get_child(index) as ColorRect
		if star == null:
			continue
		star.modulate = STAR_LIT if index < level else STAR_DIM

func _on_pressed() -> void:
	if not editable:
		return
	map_change_requested.emit()
