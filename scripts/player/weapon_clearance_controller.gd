extends Node3D
class_name WeaponClearanceController

const WeaponClearanceState = preload(
	"res://scripts/player/weapon_clearance_state.gd"
)
const WALL_CAPSULE_LENGTH := 1.55
const WALL_CAPSULE_RADIUS := 0.12
const WALL_CAPSULE_OFFSET := Vector3(0.0, 1.12, -0.62)
const WALL_RAISE_ANGLE_DEGREES := 65.0

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
var state: WeaponClearanceState

func _ready() -> void:
	state = WeaponClearanceState.new(restore_delay)

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
	if weapon.visual_anchor == null:
		_disable_clearance()
		return
	current_definition = ranged
	current_visual = weapon.visual_anchor
	visual_rest_transform = current_visual.transform
	_configure_shapes()
	normal_probe.enabled = true
	raised_probe.enabled = true
	var normal_clear := _probe_pose(normal_probe, false, Vector3.ZERO, wielder.rotation.y)
	var raised_clear := _probe_pose(raised_probe, true, Vector3.ZERO, wielder.rotation.y)
	if not normal_clear and not raised_clear:
		push_warning("Weapon %s has no safe normal or raised pose" % String(ranged.weapon_id))
		_disable_clearance()
		return
	var initial_pose := (
		WeaponClearanceState.Pose.NORMAL
		if normal_clear
		else WeaponClearanceState.Pose.RAISED
	)
	state.configure(initial_pose)
	weapon_collision.disabled = false
	_commit_pose(initial_pose)

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
	var requested_pose := state.request_pose(delta, normal_clear)
	var requested_clear := (
		normal_clear
		if requested_pose == WeaponClearanceState.Pose.NORMAL
		else raised_clear
	)
	if not requested_clear:
		return wielder.rotation.y
	if requested_pose != state.pose:
		_commit_pose(requested_pose)
	return target_yaw

func is_raised() -> bool:
	return state.pose == WeaponClearanceState.Pose.RAISED

func reset() -> void:
	_restore_visual_immediately()
	_disable_clearance()

func _configure_shapes() -> void:
	var capsules: Array[CapsuleShape3D] = [
		weapon_collision.shape as CapsuleShape3D,
		normal_probe.shape as CapsuleShape3D,
		raised_probe.shape as CapsuleShape3D,
	]
	for capsule: CapsuleShape3D in capsules:
		capsule.height = WALL_CAPSULE_LENGTH
		capsule.radius = WALL_CAPSULE_RADIUS

func _commit_pose(requested_pose: int) -> void:
	state.commit_pose(requested_pose)
	var raised := state.pose == WeaponClearanceState.Pose.RAISED
	weapon_collision.transform = _local_pose_transform(raised)
	var target := visual_rest_transform
	if raised:
		target.basis = target.basis * Basis(
			Vector3.UP,
			-deg_to_rad(WALL_RAISE_ANGLE_DEGREES)
		)
	current_visual.transform = target

func _local_pose_transform(raised: bool) -> Transform3D:
	var raise_radians := deg_to_rad(WALL_RAISE_ANGLE_DEGREES) if raised else 0.0
	var pivot := Vector3(WALL_CAPSULE_OFFSET.x, WALL_CAPSULE_OFFSET.y, 0.0)
	var raise_basis := Basis(Vector3.RIGHT, raise_radians)
	var center := pivot + raise_basis * (WALL_CAPSULE_OFFSET - pivot)
	return Transform3D(
		Basis(Vector3.RIGHT, PI * 0.5 + raise_radians),
		center
	)

func _probe_pose_transform(raised: bool, target_yaw: float) -> Transform3D:
	var local_pose := _local_pose_transform(raised)
	var facing_delta := wrapf(target_yaw - wielder.rotation.y, -PI, PI)
	var facing_basis := Basis(Vector3.UP, facing_delta)
	return Transform3D(facing_basis * local_pose.basis, facing_basis * local_pose.origin)

func _probe_pose(
	probe: ShapeCast3D,
	raised: bool,
	desired_motion: Vector3,
	target_yaw: float
) -> bool:
	probe.transform = _probe_pose_transform(raised, target_yaw)
	var cast_motion := desired_motion
	if not raised and state.pose == WeaponClearanceState.Pose.RAISED:
		cast_motion += Basis(Vector3.UP, target_yaw) * Vector3.FORWARD * restore_margin
	probe.target_position = probe.global_basis.inverse() * cast_motion
	probe.force_shapecast_update()
	return not probe.is_colliding()

func _restore_visual_immediately() -> void:
	if current_visual != null and is_instance_valid(current_visual):
		current_visual.transform = visual_rest_transform

func _disable_clearance() -> void:
	if state != null:
		state.reset()
	weapon_collision.disabled = true
	normal_probe.enabled = false
	raised_probe.enabled = false
	current_definition = null
	current_weapon = null
	current_visual = null
