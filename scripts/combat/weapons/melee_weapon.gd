extends WeaponBase
class_name MeleeWeapon

const WeaponTrigger = preload("res://scripts/combat/weapons/weapon_trigger.gd")
const LEGACY_MELEE_HITBOX_HALF_DEPTH := 0.45

var weapon_trigger: WeaponTrigger
var attack_pending := false
var attack_elapsed := 0.0
var impact_resolved := false

func _ready() -> void:
	var melee_definition := definition as MeleeWeaponDefinition
	weapon_trigger = WeaponTrigger.new(
		melee_definition.trigger_mode,
		melee_definition.attacks_per_second
	)

func _physics_process(delta: float) -> void:
	weapon_trigger.tick(delta)
	if (
		not attack_pending and
		weapon_trigger.try_attack(trigger_pressed, trigger_just_pressed)
	):
		_start_attack()
	trigger_just_pressed = false
	if not attack_pending:
		return
	attack_elapsed += maxf(delta, 0.0)
	var melee_definition := definition as MeleeWeaponDefinition
	if not impact_resolved and attack_elapsed >= melee_definition.impact_delay:
		impact_resolved = true
		var impact_origin := (
			wielder.global_transform * Transform3D(
				Basis.IDENTITY,
				melee_definition.hitbox_offset
			)
		).origin
		# 前向可及距离逐字沿用旧的 forward_distance 上限；朝向沿用 wielder 的 -basis.z
		# （基线 _resolve_melee_hit() 就是把目标偏移投影到 wielder_forward 上判定的，
		# 不是投影到 aim_direction 上；两者在身体尚未转到瞄准方向时会分叉）。
		# 横向判定由旧的 BoxShape3D 重叠改为「半宽 + 僵尸圆半径」的解析近似，
		# 在 hitbox_size.x 较小时略宽于旧口径，属已知取舍。
		emit_sim_request({
			"kind": &"melee",
			"weapon_id": melee_definition.weapon_id,
			"damage": melee_definition.damage,
			"reach": (
				-melee_definition.hitbox_offset.z +
				melee_definition.hitbox_size.z * 0.5 +
				LEGACY_MELEE_HITBOX_HALF_DEPTH
			),
			"half_width": melee_definition.hitbox_size.x * 0.5,
			"origin": Vector3(
				wielder.global_position.x,
				impact_origin.y,
				wielder.global_position.z
			),
			"aim_direction": -wielder.global_transform.basis.z,
		})
		attack_resolved.emit(
			impact_origin,
			aim_direction,
			HitResult.miss(impact_origin),
			melee_definition.visual_recoil_kick,
			melee_definition.camera_impulse_strength
		)
	if attack_elapsed >= melee_definition.attack_lock_duration:
		attack_pending = false

func set_equipped(value: bool) -> void:
	super.set_equipped(value)
	if not value:
		cancel_attack()

func cancel_attack() -> void:
	super.cancel_attack()
	_cancel_pending_impact()
	if weapon_trigger != null:
		weapon_trigger.clear_buffered_trigger()

func _cancel_pending_impact() -> void:
	attack_pending = false
	attack_elapsed = 0.0
	impact_resolved = false

func _start_attack() -> void:
	var melee_definition := definition as MeleeWeaponDefinition
	attack_pending = true
	attack_elapsed = 0.0
	impact_resolved = false
	attack_started.emit(
		melee_definition.attack_animation,
		melee_definition.attack_lock_duration
	)
