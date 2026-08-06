extends RefCounted
class_name TestPathSelection

static func select_paths(
	registered_paths: Array[String],
	requested_paths: Array[String]
) -> Dictionary:
	if requested_paths.is_empty():
		return {
			"paths": registered_paths.duplicate(),
			"errors": [],
		}
	var selected: Array[String] = []
	var errors: Array[String] = []
	for requested_path in requested_paths:
		var normalized := _normalize_path(requested_path)
		if normalized not in registered_paths:
			errors.append("Test path is not registered: %s" % normalized)
			continue
		if normalized not in selected:
			selected.append(normalized)
	return {
		"paths": selected,
		"errors": errors,
	}

static func _normalize_path(path: String) -> String:
	var normalized := path.strip_edges()
	if normalized.begins_with("./"):
		normalized = normalized.trim_prefix("./")
	if not normalized.begins_with("res://"):
		normalized = "res://" + normalized
	return normalized
