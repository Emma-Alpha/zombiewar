extends RefCounted
class_name WeaponTrigger

const FireGate = preload("res://scripts/combat/fire_gate.gd")
const WeaponDefinition = preload("res://scripts/combat/weapons/weapon_definition.gd")

var trigger_mode: int
var fire_gate: FireGate

func _init(value_trigger_mode: int, attacks_per_second: float) -> void:
	trigger_mode = value_trigger_mode
	fire_gate = FireGate.new(1.0 / maxf(attacks_per_second, 0.1))

func tick(delta: float) -> void:
	fire_gate.tick(delta)

func try_attack(trigger_pressed: bool, trigger_just_pressed: bool) -> bool:
	if trigger_just_pressed:
		fire_gate.request_shot(0.08)
	var trigger_active := trigger_just_pressed
	if trigger_mode == WeaponDefinition.TriggerMode.HOLD:
		trigger_active = trigger_pressed
	return fire_gate.try_consume(trigger_active)

func clear_buffered_trigger() -> void:
	fire_gate.buffered_trigger_remaining = 0.0

func reset() -> void:
	fire_gate.remaining = 0.0
	clear_buffered_trigger()
