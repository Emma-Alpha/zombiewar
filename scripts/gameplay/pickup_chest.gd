extends StaticBody3D
class_name PickupChest

enum RewardType {
	RIFLE,
	RIFLE_AMMO,
	OIL_BARREL,
}

signal collected(pickup: PickupChest)

const RIFLE_ID := &"rifle"
const OIL_BARREL_ID := &"oil_barrel"

@export var reward_type := RewardType.RIFLE
@export_range(1, 9999, 1) var reward_amount := 60

@onready var claim_area: Area3D = $ClaimArea
@onready var marker_ring: MeshInstance3D = $MarkerRing
@onready var marker_beacon: MeshInstance3D = $MarkerBeacon
@onready var reward_label: Label3D = $RewardLabel

var claim_locked := false

func _ready() -> void:
	claim_area.body_entered.connect(_on_body_entered)
	_apply_reward_visuals()

func _on_body_entered(body: Node3D) -> void:
	if claim_locked or not body is PlayerController:
		return
	var player := body as PlayerController
	if not player.is_alive() or not _grant_reward(player):
		return
	claim_locked = true
	claim_area.set_deferred("monitoring", false)
	collected.emit(self)
	queue_free()

func _grant_reward(player: PlayerController) -> bool:
	match reward_type:
		RewardType.RIFLE:
			return player.receive_equipment_pickup(
				RIFLE_ID,
				reward_amount,
				true
			)
		RewardType.RIFLE_AMMO:
			return player.receive_ammo_pickup(RIFLE_ID, reward_amount)
		RewardType.OIL_BARREL:
			return player.receive_equipment_pickup(
				OIL_BARREL_ID,
				reward_amount,
				false
			)
	return false

func _apply_reward_visuals() -> void:
	var color := _reward_color()
	for mesh_instance in [marker_ring, marker_beacon]:
		var material := mesh_instance.get_active_material(0) as StandardMaterial3D
		if material == null:
			continue
		material = material.duplicate() as StandardMaterial3D
		material.albedo_color = color
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 2.0
		mesh_instance.set_surface_override_material(0, material)
	reward_label.text = _reward_label_text()
	reward_label.modulate = color

func _reward_color() -> Color:
	match reward_type:
		RewardType.RIFLE:
			return Color(1.0, 0.42, 0.08, 1.0)
		RewardType.RIFLE_AMMO:
			return Color(0.12, 0.56, 1.0, 1.0)
		RewardType.OIL_BARREL:
			return Color(0.20, 0.90, 0.35, 1.0)
	return Color.WHITE

func _reward_label_text() -> String:
	match reward_type:
		RewardType.RIFLE:
			return "步枪 +%d" % reward_amount
		RewardType.RIFLE_AMMO:
			return "弹药 +%d" % reward_amount
		RewardType.OIL_BARREL:
			return "油桶 +%d" % reward_amount
	return "补给"
