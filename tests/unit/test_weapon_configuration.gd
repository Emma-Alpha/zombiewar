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
		rifle.attacks_per_second, 6.0, 0.0001, "Rifle cadence"
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
