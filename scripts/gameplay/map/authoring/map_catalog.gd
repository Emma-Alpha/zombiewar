extends Resource
class_name MapCatalog

@export var entries: Array[MapCatalogEntry] = []

func sorted_entries() -> Array[MapCatalogEntry]:
	var result: Array[MapCatalogEntry] = []
	result.append_array(entries)
	result.sort_custom(func(a: MapCatalogEntry, b: MapCatalogEntry) -> bool:
		if a.sort_order != b.sort_order:
			return a.sort_order < b.sort_order
		return String(a.map_id) < String(b.map_id)
	)
	return result
