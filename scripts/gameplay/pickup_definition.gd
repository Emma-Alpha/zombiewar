extends Resource
class_name PickupDefinition

enum RewardMode { EQUIPMENT, AMMO }

@export var reward_mode := RewardMode.EQUIPMENT
@export var item_id: StringName
@export_range(1, 9999, 1) var amount := 1
@export var auto_equip := false
@export var display_name := "补给"
@export var marker_color := Color.WHITE

func grant_to(player: PlayerController, amount_override: int = -1) -> bool:
	var grant_amount := amount if amount_override < 0 else amount_override
	if player == null or not player.is_alive() or item_id.is_empty() or grant_amount <= 0:
		return false
	match reward_mode:
		RewardMode.EQUIPMENT:
			return player.receive_equipment_pickup(item_id, grant_amount, auto_equip)
		RewardMode.AMMO:
			return player.receive_ammo_pickup(item_id, grant_amount)
	return false

func get_label_text(amount_override: int = -1) -> String:
	var label_amount := amount if amount_override < 0 else amount_override
	return "%s +%d" % [display_name, label_amount]
