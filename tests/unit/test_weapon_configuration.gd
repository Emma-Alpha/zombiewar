extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const WeaponDefinition = preload("res://scripts/combat/weapons/weapon_definition.gd")
const RangedWeaponDefinition = preload(
	"res://scripts/combat/weapons/ranged_weapon_definition.gd"
)
const MeleeWeaponDefinition = preload(
	"res://scripts/combat/weapons/melee_weapon_definition.gd"
)
const WeaponTrigger = preload("res://scripts/combat/weapons/weapon_trigger.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var pistol := load("res://resources/weapons/pistol.tres") as RangedWeaponDefinition
	var rifle := load("res://resources/weapons/rifle.tres") as RangedWeaponDefinition
	var knife := load("res://resources/weapons/knife.tres") as MeleeWeaponDefinition
	_append(failures, Assertions.expect_true(pistol != null, "Pistol definition loads"))
	_append(failures, Assertions.expect_true(rifle != null, "Rifle definition loads"))
	_append(failures, Assertions.expect_true(knife != null, "Knife definition loads"))
	if pistol == null or rifle == null or knife == null:
		return failures

	_append(failures, Assertions.expect_true(
		not _has_property(pistol, &"wall_capsule_length") and
			not _has_property(pistol, &"wall_capsule_radius") and
			not _has_property(pistol, &"wall_capsule_offset") and
			not _has_property(pistol, &"wall_raise_angle_degrees"),
		"Ranged definitions do not expose per-weapon wall-clearance overrides"
	))
	for definition: RangedWeaponDefinition in [pistol, rifle]:
		var exposes_muzzle_offset := false
		for property: Dictionary in definition.get_property_list():
			if StringName(property.get("name", &"")) == &"muzzle_anchor_offset":
				exposes_muzzle_offset = true
				break
		_append(failures, Assertions.expect_true(
			not exposes_muzzle_offset,
			"Ranged definitions do not duplicate the shared capsule muzzle origin"
		))
	_append(failures, Assertions.expect_equal(
		pistol.hit_collision_mask & 1,
		1,
		"Pistol hit mask includes solid world layer one"
	))
	_append(failures, Assertions.expect_equal(
		rifle.hit_collision_mask & 1,
		1,
		"Rifle hit mask includes solid world layer one"
	))
	_append(failures, Assertions.expect_float_near(
		pistol.base_spread_degrees,
		0.35,
		0.0001,
		"Pistol base spread"
	))
	_append(failures, Assertions.expect_float_near(
		pistol.max_spread_degrees,
		3.0,
		0.0001,
		"Pistol maximum spread"
	))
	_append(failures, Assertions.expect_float_near(
		pistol.spread_increase_per_shot_degrees,
		0.8,
		0.0001,
		"Pistol spread growth per shot"
	))
	_append(failures, Assertions.expect_float_near(
		pistol.spread_recovery_degrees_per_second,
		1.8,
		0.0001,
		"Pistol spread recovery per second"
	))
	_append(failures, Assertions.expect_float_near(
		rifle.base_spread_degrees,
		0.5,
		0.0001,
		"Rifle base spread"
	))
	_append(failures, Assertions.expect_float_near(
		rifle.max_spread_degrees,
		5.0,
		0.0001,
		"Rifle maximum spread"
	))
	_append(failures, Assertions.expect_float_near(
		rifle.spread_increase_per_shot_degrees,
		0.65,
		0.0001,
		"Rifle spread growth per shot"
	))
	_append(failures, Assertions.expect_float_near(
		rifle.spread_recovery_degrees_per_second,
		1.5,
		0.0001,
		"Rifle spread recovery per second"
	))

	_append(failures, Assertions.expect_equal(
		pistol.trigger_mode,
		WeaponDefinition.TriggerMode.PRESS,
		"Pistol uses press-only trigger mode"
	))
	_append(failures, Assertions.expect_float_near(
		pistol.damage, 35.0, 0.0001, "Pistol base damage"
	))
	_append(failures, Assertions.expect_float_near(
		pistol.attack_range, 24.0, 0.0001, "Pistol range"
	))
	_append(failures, Assertions.expect_equal(
		rifle.trigger_mode,
		WeaponDefinition.TriggerMode.HOLD,
		"Rifle uses held trigger mode"
	))
	_append(failures, Assertions.expect_float_near(
		rifle.attacks_per_second, 4.0, 0.0001, "Rifle cadence"
	))
	_append(failures, Assertions.expect_float_near(
		rifle.damage, 25.0, 0.0001, "Rifle base damage"
	))
	_append(failures, Assertions.expect_equal(
		knife.attack_animation, &"Slash", "Knife attack animation"
	))
	_append(failures, Assertions.expect_vector3_near(
		knife.hitbox_size,
		Vector3(1.5, 1.4, 1.4),
		0.0001,
		"Knife hitbox size"
	))

	var pistol_trigger := WeaponTrigger.new(
		pistol.trigger_mode,
		pistol.attacks_per_second
	)
	_append(failures, Assertions.expect_true(
		pistol_trigger.try_attack(true, true),
		"Pistol fires on the initial press"
	))
	pistol_trigger.tick(1.0 / pistol.attacks_per_second)
	_append(failures, Assertions.expect_true(
		not pistol_trigger.try_attack(true, false),
		"Pistol does not repeat while the button remains held"
	))
	_append(failures, Assertions.expect_true(
		pistol_trigger.try_attack(true, true),
		"Pistol fires again on a new press"
	))

	var rifle_trigger := WeaponTrigger.new(
		rifle.trigger_mode,
		rifle.attacks_per_second
	)
	_append(failures, Assertions.expect_true(
		rifle_trigger.try_attack(true, true),
		"Rifle fires immediately when held"
	))
	rifle_trigger.tick(1.0 / rifle.attacks_per_second)
	_append(failures, Assertions.expect_true(
		rifle_trigger.try_attack(true, false),
		"Rifle repeats while the button remains held"
	))

	var buffered_pistol := WeaponTrigger.new(
		pistol.trigger_mode,
		pistol.attacks_per_second
	)
	buffered_pistol.try_attack(true, true)
	buffered_pistol.tick(0.30)
	_append(failures, Assertions.expect_true(
		not buffered_pistol.try_attack(false, true),
		"Pistol press during cooldown waits for the gate"
	))
	buffered_pistol.tick(0.04)
	_append(failures, Assertions.expect_true(
		buffered_pistol.try_attack(false, false),
		"Buffered pistol press fires after cooldown"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)

func _has_property(value: Object, property_name: StringName) -> bool:
	for property: Dictionary in value.get_property_list():
		if StringName(property.get("name", "")) == property_name:
			return true
	return false
