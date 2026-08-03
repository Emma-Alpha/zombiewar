extends StaticBody3D
class_name ZombieTarget

const Health = preload("res://scripts/combat/health.gd")

@export var max_health: float = 50.0

@onready var visual_root: Node3D = $VisualRoot
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var health_label: Label3D = $HealthLabel

var health: Health
var animation_player: AnimationPlayer

func _ready() -> void:
	health = Health.new(max_health)
	health.changed.connect(_on_health_changed)
	health.depleted.connect(_on_depleted)
	animation_player = visual_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if animation_player != null:
		animation_player.play(&"Idle")
	_refresh_label()

func apply_damage(amount: float, _hit_position: Vector3) -> void:
	health.apply_damage(amount)
	visual_root.scale = Vector3.ONE * 1.08

func _process(delta: float) -> void:
	visual_root.scale = visual_root.scale.move_toward(Vector3.ONE, delta * 1.5)

func _on_health_changed(_current: float, _maximum: float) -> void:
	_refresh_label()

func _on_depleted() -> void:
	collision_shape.set_deferred("disabled", true)
	health_label.text = "DOWN"
	visual_root.visible = false
	await get_tree().create_timer(0.35).timeout
	queue_free()

func _refresh_label() -> void:
	health_label.text = "%d / %d" % [ceili(health.current), ceili(health.maximum)]
