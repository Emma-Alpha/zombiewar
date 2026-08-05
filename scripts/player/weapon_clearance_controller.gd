extends Node3D
class_name WeaponClearanceController

const WeaponClearanceState = preload(
	"res://scripts/player/weapon_clearance_state.gd"
)

@export var transition_duration := 0.15
@export var restore_delay := 0.15
@export var restore_margin := 0.08

@onready var weapon_collision: CollisionShape3D = $"../WeaponCollision"
@onready var normal_probe: ShapeCast3D = $NormalProbe
@onready var raised_probe: ShapeCast3D = $RaisedProbe

var wielder: CharacterBody3D
var current_weapon: WeaponBase
var current_definition: RangedWeaponDefinition
var current_visual: Node3D
var visual_rest_transform := Transform3D.IDENTITY
var visual_from_transform := Transform3D.IDENTITY
var visual_target_transform := Transform3D.IDENTITY
var visual_elapsed := 0.0
var visual_transitioning := false
var state: WeaponClearanceState

func _ready() -> void:
	state = WeaponClearanceState.new(restore_delay)
	set_process(false)

func setup(value_wielder: CharacterBody3D) -> void:
	wielder = value_wielder
	normal_probe.add_exception(wielder)
	raised_probe.add_exception(wielder)

func bind_weapon(weapon: WeaponBase) -> void:
	_restore_visual_immediately()
	current_weapon = weapon
	current_definition = null
	current_visual = null
	if weapon == null or not weapon.definition is RangedWeaponDefinition:
		_disable_clearance()
		return
	var ranged := weapon.definition as RangedWeaponDefinition
	if not ranged.has_wall_clearance_profile() or weapon.visual_anchor == null:
		push_warning(
			"Weapon %s has no valid wall-clearance profile or visual anchor" %
			String(ranged.weapon_id)
		)
		_disable_clearance()
		return
	current_definition = ranged
	current_visual = weapon.visual_anchor
	visual_rest_transform = current_visual.transform
	_configure_shapes(ranged)
	state.reset()
	var normal_clear := _probe_pose(normal_probe, false, Vector3.ZERO, wielder.rotation.y)
	var raised_clear := _probe_pose(raised_probe, true, Vector3.ZERO, wielder.rotation.y)
	if not normal_clear and not raised_clear:
		push_warning(
			"Weapon %s has no safe normal or raised pose" %
			String(ranged.weapon_id)
		)
		_disable_clearance()
		return
	state.configure(true, normal_clear, raised_clear)
	_apply_pose(state.pose)

func resolve_facing_yaw(
	delta: float,
	desired_motion: Vector3,
	target_yaw: float
) -> float:
	if current_definition == null or state.pose == WeaponClearanceState.Pose.DISABLED:
		return target_yaw
	var normal_clear := _probe_pose(
		normal_probe,
		false,
		desired_motion,
		target_yaw
	)
	var raised_clear := _probe_pose(
		raised_probe,
		true,
		desired_motion,
		target_yaw
	)
	var changed := state.update(delta, normal_clear, raised_clear)
	if changed:
		_apply_pose(state.pose)
	if not normal_clear and not raised_clear:
		return wielder.rotation.y
	weapon_collision.transform = _pose_transform(is_raised(), target_yaw)
	return target_yaw

func observe_trigger(trigger_pressed: bool) -> void:
	state.observe_trigger(trigger_pressed)

func can_fire() -> bool:
	if current_definition == null or state.pose == WeaponClearanceState.Pose.DISABLED:
		return true
	return state.can_fire(not visual_transitioning)

func is_raised() -> bool:
	return state.pose == WeaponClearanceState.Pose.RAISED

func reset() -> void:
	_restore_visual_immediately()
	_disable_clearance()

func _configure_shapes(definition: RangedWeaponDefinition) -> void:
	var collision_capsule := weapon_collision.shape as CapsuleShape3D
	var normal_capsule := normal_probe.shape as CapsuleShape3D
	var raised_capsule := raised_probe.shape as CapsuleShape3D
	for capsule in [collision_capsule, normal_capsule, raised_capsule]:
		capsule.height = definition.wall_capsule_length
		capsule.radius = definition.wall_capsule_radius
	weapon_collision.disabled = false
	normal_probe.enabled = true
	raised_probe.enabled = true

func _apply_pose(pose: int) -> void:
	if current_definition == null:
		return
	var raised := pose == WeaponClearanceState.Pose.RAISED
	weapon_collision.transform = _pose_transform(raised, wielder.rotation.y)
	var target := visual_rest_transform
	if raised:
		target.basis = target.basis * Basis(
			Vector3.UP,
			-deg_to_rad(current_definition.wall_raise_angle_degrees)
		)
	_begin_visual_transition(target)

func _pose_transform(raised: bool, target_yaw: float) -> Transform3D:
	var offset := current_definition.wall_capsule_offset
	var raise_radians := (
		deg_to_rad(current_definition.wall_raise_angle_degrees)
		if raised else 0.0
	)
	var pivot := Vector3(offset.x, offset.y, 0.0)
	var raise_basis := Basis(Vector3.RIGHT, raise_radians)
	var center := pivot + raise_basis * (offset - pivot)
	var facing_delta := wrapf(target_yaw - wielder.rotation.y, -PI, PI)
	var facing_basis := Basis(Vector3.UP, facing_delta)
	var capsule_basis := facing_basis * Basis(
		Vector3.RIGHT,
		PI * 0.5 + raise_radians
	)
	return Transform3D(capsule_basis, facing_basis * center)

func _probe_pose(
	probe: ShapeCast3D,
	raised: bool,
	desired_motion: Vector3,
	target_yaw: float
) -> bool:
	probe.transform = _pose_transform(raised, target_yaw)
	var cast_motion := desired_motion
	if not raised and state.pose == WeaponClearanceState.Pose.RAISED:
		cast_motion += Basis(Vector3.UP, target_yaw) * Vector3.FORWARD * restore_margin
	probe.target_position = probe.global_basis.inverse() * cast_motion
	probe.force_shapecast_update()
	return not probe.is_colliding()

func _begin_visual_transition(target: Transform3D) -> void:
	if current_visual == null:
		return
	if current_visual.transform.is_equal_approx(target):
		current_visual.transform = target
		visual_transitioning = false
		set_process(false)
		return
	visual_from_transform = current_visual.transform
	visual_target_transform = target
	visual_elapsed = 0.0
	visual_transitioning = true
	set_process(true)

func _process(delta: float) -> void:
	if not visual_transitioning or current_visual == null:
		set_process(false)
		return
	visual_elapsed += maxf(delta, 0.0)
	var weight := minf(visual_elapsed / maxf(transition_duration, 0.001), 1.0)
	var eased := smoothstep(0.0, 1.0, weight)
	current_visual.transform = visual_from_transform.interpolate_with(
		visual_target_transform,
		eased
	)
	if weight >= 1.0:
		current_visual.transform = visual_target_transform
		visual_transitioning = false
		set_process(false)

func _restore_visual_immediately() -> void:
	if current_visual != null and is_instance_valid(current_visual):
		current_visual.transform = visual_rest_transform
	visual_transitioning = false
	visual_elapsed = 0.0
	set_process(false)

func _disable_clearance() -> void:
	if state != null:
		state.reset()
	weapon_collision.disabled = true
	normal_probe.enabled = false
	raised_probe.enabled = false
	current_definition = null
	current_weapon = null
	current_visual = null
