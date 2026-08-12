extends Resource
class_name ShopOfferDefinition

## 波间商店的一个可售项。
##
## offer_type 决定购买时走模拟（stat/heal）还是表现层（weapon/passive/ammo）：
##   stat    —— 属性升级，进模拟成长表（确定性）
##   heal    —— 回血，进模拟 tick_player_heal_events
##   weapon  —— 买武器，表现层 EquipmentController.grant_item
##   passive —— 买被动，表现层 PlayerController.runtime_passive_id
##   ammo    —— 补弹药，表现层 EquipmentController.add_ammo
## 类型字段按 offer_type 各读各的，其余忽略。

enum OfferType { STAT, HEAL, WEAPON, PASSIVE, AMMO }

@export var offer_type := OfferType.STAT
## 属性升级用的统计种类（offer_type == STAT 时读）：
## 0=伤害  1=最大生命  2=移速
@export var stat_index := 0
## 属性升级的倍率（伤害/移速）或加值（生命），与 character 的成长语义一致。
@export var stat_amount := 1.0
## 回血量（offer_type == HEAL 时读）。
@export var heal_amount := 10.0
## 武器 id（offer_type == WEAPON 时读，对应 resources/weapons/*.tres 的 weapon_id）。
@export var weapon_id: StringName = &""
## 被动 id（offer_type == PASSIVE 时读，同 character passive_id 的允许集合）。
@export var passive_id: StringName = &""
## 弹药量（offer_type == AMMO 时读）。
@export var ammo_amount := 20
## 售价（材料）。
@export_range(1, 9999, 1) var price := 10
@export var display_name := ""

func validate_configuration() -> PackedStringArray:
	var errors := PackedStringArray()
	if price <= 0:
		errors.append("price must be positive")
	if display_name.is_empty():
		errors.append("display_name is required")
	match offer_type:
		OfferType.STAT:
			if stat_index < 0 or stat_index > 2:
				errors.append("stat_index must be 0(damage)/1(max_health)/2(move_speed)")
			if stat_amount <= 0.0:
				errors.append("stat_amount must be positive")
		OfferType.HEAL:
			if heal_amount <= 0.0:
				errors.append("heal_amount must be positive")
		OfferType.WEAPON:
			if weapon_id.is_empty():
				errors.append("weapon_id is required")
		OfferType.PASSIVE:
			if passive_id.is_empty():
				errors.append("passive_id is required")
		OfferType.AMMO:
			if ammo_amount <= 0:
				errors.append("ammo_amount must be positive")
		_:
			errors.append("offer_type is invalid")
	return errors
