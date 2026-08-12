extends Control
class_name InventoryPanel

## 背包面板：Brotato 式分区布局。
##
## 遮罩层压暗背景，顶部标题+材料，下面按分类分区：
##   武器区（横排格子） / 弹药区 / 油桶 / 改装件
## 数据从 SimWorld 逐玩家背包槽位读（确定性），表现层只读不改。
## B 键打开/关闭由 arena 控制。

const SLOT_COUNT := 12
const ATLAS_COLUMNS := 5

## 分类 -> 显示名 + 颜色
const CATEGORY_LABELS := {
	0: "武器",
	1: "弹药",
	2: "油桶",
	3: "改装",
}

@onready var atlas_texture: Texture2D = preload("res://assets/ui/inventory/inventory_atlas.png")
@onready var title_label: Label = $Margin/Panel/VBox/TitleLabel
@onready var material_label: Label = $Margin/Panel/VBox/MaterialLabel
@onready var sections_box: VBoxContainer = $Margin/Panel/VBox/Sections

var _sim_world = null
var _player_slot := 0
var _profile_catalog: Array[InventoryProfile] = []

func setup(sim_world, player_slot: int, profile_catalog: Array[InventoryProfile]) -> void:
	_sim_world = sim_world
	_player_slot = player_slot
	_profile_catalog = profile_catalog
	_refresh()

func _refresh() -> void:
	if _sim_world == null or sections_box == null:
		return
	# 材料数
	if material_label != null:
		material_label.text = "材料 %d" % _sim_world.get_player_material(_player_slot)
	# 清空旧分区
	for child in sections_box.get_children():
		child.queue_free()
	# 收集 12 槽的物品，按分类分组
	var by_category := {}
	for i in range(SLOT_COUNT):
		var profile_index: int = _sim_world.get_inventory_slot_profile(_player_slot, i)
		var amount: int = _sim_world.get_inventory_slot_amount(_player_slot, i)
		if profile_index < 0 or amount <= 0:
			continue
		var profile := _profile_for_index(profile_index)
		if profile == null:
			continue
		var cat: int = profile.category
		if not by_category.has(cat):
			by_category[cat] = []
		by_category[cat].append({"profile": profile, "amount": amount})
	# 按分类顺序渲染分区（武器 0 / 弹药 1 / 油桶 2 / 改装 3）
	for cat in [0, 1, 2, 3]:
		if not by_category.has(cat):
			continue
		var section := _make_section(cat, by_category[cat])
		sections_box.add_child(section)

## 做一个分类分区：标签 + 横排格子。
func _make_section(category: int, items: Array) -> Control:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	# 分类标签
	var label := Label.new()
	label.text = CATEGORY_LABELS.get(category, "其他")
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.95, 0.66, 0.0, 1.0))
	vbox.add_child(label)
	# 格子横排（HBoxContainer 换行不了，改用 GridContainer）
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	for item in items:
		grid.add_child(_make_item_cell(item["profile"], item["amount"]))
	vbox.add_child(grid)
	return vbox

## 做一个物品格子：图标 + 数量角标。
func _make_item_cell(profile: InventoryProfile, amount: int) -> Control:
	var cell := PanelContainer.new()
	cell.custom_minimum_size = Vector2(64, 64)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.1, 0.08, 0.95)
	style.border_color = Color(0.3, 0.35, 0.28, 1.0)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	cell.add_theme_stylebox_override("panel", style)

	# 图标
	var icon := TextureRect.new()
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if profile.icon_region != null and profile.icon_region.size.x > 0.0:
		var atlas := AtlasTexture.new()
		atlas.atlas = atlas_texture
		atlas.region = profile.icon_region
		icon.texture = atlas
	cell.add_child(icon)

	# 数量角标（右下角）
	var count := Label.new()
	count.text = "×%d" % amount if amount > 1 else ""
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count.add_theme_font_size_override("font_size", 12)
	count.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	cell.add_child(count)

	# 物品名 tooltip（悬停提示）
	cell.tooltip_text = profile.display_name
	return cell

func _profile_for_index(profile_index: int) -> InventoryProfile:
	if profile_index < 0 or profile_index >= _profile_catalog.size():
		return null
	return _profile_catalog[profile_index]
