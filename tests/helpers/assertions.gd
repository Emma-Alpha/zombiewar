extends RefCounted
class_name Assertions

static func expect_true(condition: bool, message: String) -> String:
	return "" if condition else message

static func expect_equal(actual: Variant, expected: Variant, message: String) -> String:
	if actual == expected:
		return ""
	return "%s — expected %s, got %s" % [message, str(expected), str(actual)]

static func expect_float_near(actual: float, expected: float, tolerance: float, message: String) -> String:
	if absf(actual - expected) <= tolerance:
		return ""
	return "%s — expected %.4f, got %.4f" % [message, expected, actual]

static func expect_vector3_near(actual: Vector3, expected: Vector3, tolerance: float, message: String) -> String:
	if actual.distance_to(expected) <= tolerance:
		return ""
	return "%s — expected %s, got %s" % [message, str(expected), str(actual)]
