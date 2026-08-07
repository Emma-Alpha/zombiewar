extends StaticBody3D
class_name PickupChest

const PickupDefinition = preload("res://scripts/gameplay/pickup_definition.gd")

signal collected(pickup: PickupChest)

@export var definition: PickupDefinition

@onready var claim_area: Area3D = $ClaimArea
@onready var marker_ring: MeshInstance3D = $MarkerRing
@onready var marker_beacon: MeshInstance3D = $MarkerBeacon
@onready var reward_label: Label3D = $RewardLabel

var claim_locked := false

func _ready() -> void:
	claim_area.body_entered.connect(_on_body_entered)
	_apply_reward_visuals()

func configure(value: PickupDefinition) -> void:
	definition = value
	if is_node_ready():
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
	return definition != null and definition.grant_to(player)

func _apply_reward_visuals() -> void:
	var color: Color = definition.marker_color if definition != null else Color.WHITE
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
	reward_label.text = get_reward_label_text()
	reward_label.modulate = color

func get_reward_label_text() -> String:
	return definition.get_label_text() if definition != null else "未配置补给"
