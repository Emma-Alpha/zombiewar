extends Control
class_name InventoryPanel

## 背包面板：12 槽网格，显示图标 + 数量。
##
## 数据从 SimWorld 的逐玩家背包槽位读（确定性，表现层只读不改）。
## Tab 打开/关闭由 arena 控制。图标用 inventory_atlas.png（5×4 网格，64×64/cell），
## icon_region 定位。

## 背包槽位数（与 SimWorld.INVENTORY_SLOT_COUNT 一致）
const SLOT_COUNT := 12
## 图集列数
const ATLAS_COLUMNS := 5

signal closed

@onready var grid: GridContainer = $Margin/VBox/Grid
@onready var atlas_texture: Texture2D = preload("res://assets/ui/inventory/inventory_atlas.png")

var _slot_cells: Array[Control] = []
var _sim_world = null
var _player_slot := 0
var _profile_catalog: Array[InventoryProfile] = []

func setup(sim_world, player_slot: int, profile_catalog: Array[InventoryProfile]) -> void:
	_sim_world = sim_world
	_player_slot = player_slot
	_profile_catalog = profile_catalog
	_build_grid()
	_refresh()

## 建 12 槽格子（4 列 × 3 行）。
func _build_grid() -> void:
	if grid == null:
		return
	for child in grid.get_children():
		child.queue_free()
	_slot_cells.clear()
	grid.columns = 4
	for i in range(SLOT_COUNT):
		var cell := _make_slot_cell(i)
		grid.add_child(cell)
		_slot_cells.append(cell)

func _make_slot_cell(index: int) -> Control:
	var cell := PanelContainer.new()
	cell.custom_minimum_size = Vector2(72, 72)
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	cell.add_child(vbox)
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(48, 48)
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	vbox.add_child(icon)
	var count_label := Label.new()
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(count_label)
	return cell

## 从模拟层读槽位，刷新图标 + 数量。
func _refresh() -> void:
	if _sim_world == null or _slot_cells.is_empty():
		return
	for i in range(_slot_cells.size()):
		var cell := _slot_cells[i]
		var icon := cell.get_child(0).get_child(0) as TextureRect
		var count_label := cell.get_child(0).get_child(1) as Label
		var profile_index: int = _sim_world.get_inventory_slot_profile(_player_slot, i)
		var amount: int = _sim_world.get_inventory_slot_amount(_player_slot, i)
		if profile_index < 0 or amount <= 0:
			icon.texture = null
			count_label.text = ""
			continue
		# 图标：按 profile 的 icon_region 从图集裁 64×64
		var profile := _profile_for_index(profile_index)
		if profile != null and profile.icon_region != null:
			var region: Rect2 = profile.icon_region
			if region.size.x > 0.0 and region.size.y > 0.0:
				var atlas := AtlasTexture.new()
				atlas.atlas = atlas_texture
				atlas.region = region
				icon.texture = atlas
		count_label.text = "×%d" % amount

func _profile_for_index(profile_index: int) -> InventoryProfile:
	if profile_index < 0 or profile_index >= _profile_catalog.size():
		return null
	return _profile_catalog[profile_index]

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_inventory"):
		closed.emit()
		get_viewport().set_input_as_handled()
