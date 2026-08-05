extends RefCounted
class_name BloodTrailState

const SAMPLE_SPACING := 0.36
const MAX_DURATION := 0.75
const MAX_MARKS := 8
const STOP_SPEED_MARGIN := 0.25

var active := false
var previous_position := Vector3.ZERO
var distance_to_next := SAMPLE_SPACING
var elapsed := 0.0
var marks_emitted := 0
var intensity := 1.0

func start(world_position: Vector3, hit_intensity: float) -> void:
	active = true
	previous_position = world_position
	distance_to_next = SAMPLE_SPACING
	elapsed = 0.0
	marks_emitted = 0
	intensity = clampf(hit_intensity, 0.75, 1.35)

func advance(
	current_position: Vector3,
	delta: float,
	planar_speed: float,
	normal_move_speed: float
) -> Array[Dictionary]:
	var samples: Array[Dictionary] = []
	if not active:
		return samples
	var frame_duration := maxf(delta, 0.0)
	var sample_duration := minf(frame_duration, maxf(MAX_DURATION - elapsed, 0.0))
	var sample_fraction := sample_duration / frame_duration if frame_duration > 0.000001 else 0.0
	var start := Vector3(previous_position.x, current_position.y, previous_position.z)
	var full_finish := Vector3(current_position.x, current_position.y, current_position.z)
	var finish := start.lerp(full_finish, sample_fraction)
	var segment := finish - start
	var segment_length := segment.length()
	if segment_length > 0.000001:
		var direction := segment / segment_length
		var travelled := 0.0
		while (
			segment_length - travelled + 0.000001 >= distance_to_next and
			marks_emitted < MAX_MARKS
		):
			travelled += distance_to_next
			marks_emitted += 1
			samples.append({
				"position": start + direction * travelled,
				"direction": direction,
				"progress": float(marks_emitted) / float(MAX_MARKS),
				"intensity": intensity,
			})
			distance_to_next = SAMPLE_SPACING
		distance_to_next -= maxf(segment_length - travelled, 0.0)
	previous_position = current_position
	elapsed = minf(elapsed + frame_duration, MAX_DURATION)
	if (
		elapsed >= MAX_DURATION or
		marks_emitted >= MAX_MARKS or
		planar_speed <= normal_move_speed + STOP_SPEED_MARGIN
	):
		active = false
	return samples
