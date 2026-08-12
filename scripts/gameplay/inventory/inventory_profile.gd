extends Resource
class_name InventoryProfile

## 只读物品元数据。运行时数量只存在 InventorySlot，绝不改写这个共享 .tres。
enum Category { WEAPON, AMMO, OIL, WEAPON_MOD }

## Task 1 只固定 atlas 坐标契约；实际 PNG 由后续图标任务提供。
const ATLAS_COLUMNS := 5
const ATLAS_ROWS := 4
const ATLAS_CELL_SIZE := Vector2(64, 64)
const ATLAS_SIZE := Vector2(
	ATLAS_COLUMNS * ATLAS_CELL_SIZE.x,
	ATLAS_ROWS * ATLAS_CELL_SIZE.y
)

@export var profile_id: StringName = &""
@export var category := Category.WEAPON
@export var display_name := ""
@export_multiline var description := ""
@export_range(0, 9999, 1) var max_stack := 1
@export var weapon_id: StringName = &""
@export var mod_id: StringName = &""
@export var icon_region := Rect2()

## inventory_profiles.tres 用同一轻量 Resource 作为目录根，避免引入第二种
## 可变数据模型。根对象的上述单项字段不参与运行时 profile 表。
@export var profiles: Array[InventoryProfile] = []


static func is_icon_region_inside_atlas(region: Rect2) -> bool:
	return (
		region.position.x >= 0.0
		and region.position.y >= 0.0
		and region.size.x > 0.0
		and region.size.y > 0.0
		and region.end.x <= ATLAS_SIZE.x
		and region.end.y <= ATLAS_SIZE.y
		and fmod(region.position.x, ATLAS_CELL_SIZE.x) == 0.0
		and fmod(region.position.y, ATLAS_CELL_SIZE.y) == 0.0
		and region.size == ATLAS_CELL_SIZE
	)
