@tool
extends Control

signal create_map_requested(request: Dictionary)
signal open_scene_requested(path: String)
signal place_prefab_requested(entry: PrefabCatalogEntry)
signal save_requested()

@onready var search_edit: LineEdit = %SearchEdit
@onready var prefab_tree: Tree = %PrefabTree
@onready var map_inspector: Node = %MapInspector
@onready var wave_list: ItemList = %WaveList
@onready var wave_inspector: Node = %WaveInspector
@onready var drop_tree: Tree = %DropTree
@onready var drop_inspector: Node = %DropInspector
@onready var catalog_inspector: Node = %CatalogInspector
@onready var status_label: Label = %StatusLabel
@onready var new_map_dialog: ConfirmationDialog = %NewMapDialog
@onready var open_map_dialog: FileDialog = %OpenMapDialog

var _prefab_catalog: PrefabCatalog
var _definition: MapDefinition
var _map_catalog: MapCatalog
var _catalog_entry: MapCatalogEntry
var _cached_catalog_entry: MapCatalogEntry
var _context: Dictionary = {}
var _pending_wave_selection: MapWaveDefinition
var _pending_drop_selection: Resource


func _ready() -> void:
	%NewMapButton.pressed.connect(func() -> void: new_map_dialog.popup_centered())
	%OpenMapButton.pressed.connect(func() -> void: open_map_dialog.popup_centered())
	%SaveMapButton.pressed.connect(func() -> void: save_requested.emit())
	%PlaceButton.pressed.connect(_request_selected_prefab)
	search_edit.text_changed.connect(func(_text: String) -> void: _rebuild_prefab_tree())
	prefab_tree.item_activated.connect(_request_selected_prefab)
	new_map_dialog.connect("request_ready",
		func(request: Dictionary) -> void: create_map_requested.emit(request)
	)
	open_map_dialog.file_selected.connect(
		func(path: String) -> void: open_scene_requested.emit(path)
	)
	wave_list.item_selected.connect(_select_wave)
	%AddWaveButton.pressed.connect(_add_wave)
	%DeleteWaveButton.pressed.connect(_delete_wave)
	%MoveWaveUpButton.pressed.connect(func() -> void: _move_wave(-1))
	%MoveWaveDownButton.pressed.connect(func() -> void: _move_wave(1))
	drop_tree.item_selected.connect(_select_drop_resource)
	prefab_tree.set_drag_forwarding(
		_get_prefab_drag_data,
		Callable(),
		Callable()
	)
	%AddRuleButton.pressed.connect(_add_death_rule)
	%AddGroupButton.pressed.connect(_add_death_group)
	%AddEventButton.pressed.connect(_add_death_event)
	%DeleteDropButton.pressed.connect(_delete_drop_resource)
	%RemoveCatalogButton.pressed.connect(_remove_catalog_entry)
	%AddCatalogButton.pressed.connect(_add_catalog_entry)
	_rebuild_prefab_tree()


func set_context(context: Dictionary) -> void:
	_disconnect_definition()
	_context = context
	_definition = context.get("definition") as MapDefinition
	_map_catalog = context.get("map_catalog") as MapCatalog
	_cached_catalog_entry = null
	_pending_wave_selection = null
	_pending_drop_selection = null
	if _definition != null and not _definition.changed.is_connected(_on_definition_changed):
		_definition.changed.connect(_on_definition_changed)
	map_inspector.edit(_definition)
	_rebuild_wave_list()
	_rebuild_drop_tree()
	_find_catalog_entry()
	if _definition == null:
		set_status("未打开地图")
	else:
		set_status("正在编辑：%s" % _definition.display_name)


func _exit_tree() -> void:
	_disconnect_definition()


func _disconnect_definition() -> void:
	if _definition != null and _definition.changed.is_connected(_on_definition_changed):
		_definition.changed.disconnect(_on_definition_changed)


func _on_definition_changed() -> void:
	var selected_wave_index := -1
	var selected_wave_items := wave_list.get_selected_items()
	if not selected_wave_items.is_empty():
		selected_wave_index = selected_wave_items[0]
	var inspected_wave := wave_inspector.call("get_edited_object") as MapWaveDefinition
	var wave_to_select := _pending_wave_selection
	_pending_wave_selection = null
	if wave_to_select == null and inspected_wave != null and _definition.waves.has(inspected_wave):
		wave_to_select = inspected_wave
	var wave_index := _definition.waves.find(wave_to_select)
	if wave_index < 0 and inspected_wave == null and not _definition.waves.is_empty():
		wave_index = clampi(selected_wave_index, 0, _definition.waves.size() - 1)
	_rebuild_wave_list(wave_index)

	var inspected_drop := drop_inspector.call("get_edited_object") as Resource
	var drop_to_select := _pending_drop_selection
	_pending_drop_selection = null
	if drop_to_select == null and _definition_contains_drop_resource(inspected_drop):
		drop_to_select = inspected_drop
	if not _definition_contains_drop_resource(drop_to_select):
		drop_to_select = null
	_rebuild_drop_tree(drop_to_select)


func set_status(message: String, is_error: bool = false) -> void:
	status_label.text = message
	status_label.modulate = Color(1.0, 0.45, 0.45) if is_error else Color.WHITE


func set_prefab_catalog(catalog: PrefabCatalog) -> void:
	_prefab_catalog = catalog
	if prefab_tree == null:
		prefab_tree = get_node_or_null("Root/Workspace/PrefabPanel/PrefabTree") as Tree
	if search_edit == null:
		search_edit = get_node_or_null("Root/Workspace/PrefabPanel/SearchEdit") as LineEdit
	if prefab_tree != null and search_edit != null:
		_rebuild_prefab_tree()


func _rebuild_prefab_tree() -> void:
	prefab_tree.clear()
	var root_item := prefab_tree.create_item()
	if _prefab_catalog == null:
		return
	var query := search_edit.text.strip_edges().to_lower()
	var categories: Dictionary[String, Array] = {}
	for entry in _prefab_catalog.entries:
		if entry == null or not _prefab_matches(entry, query):
			continue
		var category := String(entry.category)
		if not categories.has(category):
			categories[category] = []
		categories[category].append(entry)
	var category_names := categories.keys()
	category_names.sort_custom(func(a: String, b: String) -> bool:
		return a.naturalnocasecmp_to(b) < 0
	)
	for category in category_names:
		var category_item := prefab_tree.create_item(root_item)
		category_item.set_text(0, category)
		category_item.set_selectable(0, false)
		var entries: Array = categories[category]
		entries.sort_custom(func(a: PrefabCatalogEntry, b: PrefabCatalogEntry) -> bool:
			return a.display_name.naturalnocasecmp_to(b.display_name) < 0
		)
		for entry: PrefabCatalogEntry in entries:
			var item := prefab_tree.create_item(category_item)
			item.set_text(0, entry.display_name)
			item.set_metadata(0, entry)
			if entry.thumbnail != null:
				item.set_icon(0, entry.thumbnail)


func _prefab_matches(entry: PrefabCatalogEntry, query: String) -> bool:
	if query.is_empty():
		return true
	if entry.display_name.to_lower().contains(query):
		return true
	if String(entry.category).to_lower().contains(query):
		return true
	for tag in entry.search_tags:
		if tag.to_lower().contains(query):
			return true
	return false


func _request_selected_prefab() -> void:
	var item := prefab_tree.get_selected()
	if item == null:
		return
	var entry := item.get_metadata(0) as PrefabCatalogEntry
	if entry != null:
		place_prefab_requested.emit(entry)


func _get_prefab_drag_data(_position: Vector2) -> Variant:
	var item := prefab_tree.get_selected()
	if item == null:
		return null
	var entry := item.get_metadata(0) as PrefabCatalogEntry
	if entry == null:
		return null
	return {"prefab_entry": entry}


func _rebuild_wave_list(selected_index: int = -1) -> void:
	wave_list.clear()
	wave_inspector.edit(null)
	if _definition == null:
		return
	for index in _definition.waves.size():
		var wave := _definition.waves[index]
		wave_list.add_item("波次 %d" % (index + 1))
		wave_list.set_item_metadata(index, wave)
	if selected_index >= 0 and selected_index < wave_list.item_count:
		wave_list.select(selected_index)
		_select_wave(selected_index)


func _select_wave(index: int) -> void:
	if index < 0 or index >= wave_list.item_count:
		wave_inspector.edit(null)
		return
	var wave := wave_list.get_item_metadata(index) as MapWaveDefinition
	wave_inspector.edit(wave)


func _add_wave() -> void:
	if _definition == null:
		return
	var wave := MapWaveDefinition.new()
	_definition.waves.append(wave)
	_pending_wave_selection = wave
	_definition.emit_changed()


func _delete_wave() -> void:
	if _definition == null:
		return
	var selected := wave_list.get_selected_items()
	if selected.is_empty():
		return
	var index := selected[0]
	if index < 0 or index >= _definition.waves.size():
		return
	var selected_wave := wave_list.get_item_metadata(index) as MapWaveDefinition
	if selected_wave == null or _definition.waves[index] != selected_wave:
		return
	_definition.waves.remove_at(index)
	_definition.emit_changed()


func _move_wave(offset: int) -> void:
	if _definition == null:
		return
	var selected := wave_list.get_selected_items()
	if selected.is_empty():
		return
	var from_index := selected[0]
	if from_index < 0 or from_index >= _definition.waves.size():
		return
	var to_index := from_index + offset
	if to_index < 0 or to_index >= _definition.waves.size():
		return
	var wave := wave_list.get_item_metadata(from_index) as MapWaveDefinition
	if wave == null or _definition.waves[from_index] != wave:
		return
	_definition.waves.remove_at(from_index)
	_definition.waves.insert(to_index, wave)
	_pending_wave_selection = wave
	_definition.emit_changed()


func _rebuild_drop_tree(selected_resource: Resource = null) -> void:
	drop_tree.clear()
	var root_item := drop_tree.create_item()
	drop_inspector.edit(null)
	if _definition == null:
		return
	for rule_index in _definition.zombie_death_rules.size():
		var rule := _definition.zombie_death_rules[rule_index]
		var rule_item := drop_tree.create_item(root_item)
		rule_item.set_text(0, "规则 %d" % (rule_index + 1))
		rule_item.set_metadata(0, rule)
		_select_tree_item_for_resource(rule_item, selected_resource)
		if rule == null:
			continue
		for group_index in rule.groups.size():
			var group := rule.groups[group_index]
			var group_item := drop_tree.create_item(rule_item)
			group_item.set_text(0, "分组 %d" % (group_index + 1))
			group_item.set_metadata(0, group)
			_select_tree_item_for_resource(group_item, selected_resource)
			if group == null:
				continue
			for event_index in group.events.size():
				var event := group.events[event_index]
				var event_item := drop_tree.create_item(group_item)
				event_item.set_text(0, "事件 %d" % (event_index + 1))
				event_item.set_metadata(0, event)
				_select_tree_item_for_resource(event_item, selected_resource)


func _select_tree_item_for_resource(item: TreeItem, resource: Resource) -> void:
	if resource != null and item.get_metadata(0) == resource:
		item.select(0)
		drop_inspector.edit(resource)


func _selected_drop_resource() -> Resource:
	var item := drop_tree.get_selected()
	if item == null:
		return null
	return item.get_metadata(0) as Resource


func _select_drop_resource() -> void:
	drop_inspector.edit(_selected_drop_resource())


func _add_death_rule() -> void:
	if _definition == null:
		return
	var rule := MapZombieDeathRuleDefinition.new()
	_definition.zombie_death_rules.append(rule)
	_pending_drop_selection = rule
	_definition.emit_changed()


func _add_death_group() -> void:
	if _definition == null:
		return
	var rule := _selected_drop_rule()
	if rule == null:
		return
	var group := DeathEventGroupDefinition.new()
	rule.groups.append(group)
	rule.emit_changed()
	_pending_drop_selection = group
	_definition.emit_changed()


func _add_death_event() -> void:
	if _definition == null:
		return
	var group := _selected_drop_group()
	if group == null:
		return
	var event := DeathEventDefinition.new()
	group.events.append(event)
	group.emit_changed()
	_pending_drop_selection = event
	_definition.emit_changed()


func _selected_drop_rule() -> MapZombieDeathRuleDefinition:
	var item := drop_tree.get_selected()
	while item != null:
		var resource := item.get_metadata(0) as Resource
		if resource is MapZombieDeathRuleDefinition:
			return resource as MapZombieDeathRuleDefinition
		item = item.get_parent()
	return null


func _selected_drop_group() -> DeathEventGroupDefinition:
	var item := drop_tree.get_selected()
	while item != null:
		var resource := item.get_metadata(0) as Resource
		if resource is DeathEventGroupDefinition:
			return resource as DeathEventGroupDefinition
		item = item.get_parent()
	return null


func _delete_drop_resource() -> void:
	if _definition == null:
		return
	var selected := _selected_drop_resource()
	if selected == null or not _definition_contains_drop_resource(selected):
		return
	if selected is DeathEventDefinition:
		var group := _selected_drop_group()
		if group != null:
			group.events.erase(selected as DeathEventDefinition)
			group.emit_changed()
	elif selected is DeathEventGroupDefinition:
		var rule := _selected_drop_rule()
		if rule != null:
			rule.groups.erase(selected as DeathEventGroupDefinition)
			rule.emit_changed()
	elif selected is MapZombieDeathRuleDefinition:
		_definition.zombie_death_rules.erase(selected as MapZombieDeathRuleDefinition)
	_definition.emit_changed()


func _definition_contains_drop_resource(resource: Resource) -> bool:
	if _definition == null or resource == null:
		return false
	for rule in _definition.zombie_death_rules:
		if rule == resource:
			return true
		if rule == null:
			continue
		for group in rule.groups:
			if group == resource:
				return true
			if group == null:
				continue
			for event in group.events:
				if event == resource:
					return true
	return false


func _find_catalog_entry() -> void:
	_catalog_entry = null
	if _definition != null and _map_catalog != null:
		for entry in _map_catalog.entries:
			if entry != null and entry.map_id == _definition.map_id:
				_catalog_entry = entry
				_cached_catalog_entry = entry.duplicate(true) as MapCatalogEntry
				break
	catalog_inspector.edit(_catalog_entry)
	%RemoveCatalogButton.disabled = _catalog_entry == null
	%AddCatalogButton.disabled = (
		_catalog_entry != null
		or _cached_catalog_entry == null
		or _cached_catalog_entry.entry_scene == null
	)


func _remove_catalog_entry() -> void:
	if _map_catalog == null or _catalog_entry == null:
		return
	_cached_catalog_entry = _catalog_entry.duplicate(true) as MapCatalogEntry
	_map_catalog.entries.erase(_catalog_entry)
	_map_catalog.emit_changed()
	_catalog_entry = null
	catalog_inspector.edit(null)
	%RemoveCatalogButton.disabled = true
	%AddCatalogButton.disabled = _cached_catalog_entry.entry_scene == null


func _add_catalog_entry() -> void:
	if _definition == null or _map_catalog == null:
		return
	_find_catalog_entry()
	if _catalog_entry != null:
		return
	if _cached_catalog_entry == null or _cached_catalog_entry.entry_scene == null:
		%AddCatalogButton.disabled = true
		set_status("当前地图没有可恢复的目录入口场景", true)
		return
	var entry := _cached_catalog_entry.duplicate(true) as MapCatalogEntry
	_map_catalog.entries.append(entry)
	_map_catalog.emit_changed()
	_catalog_entry = entry
	_cached_catalog_entry = entry.duplicate(true) as MapCatalogEntry
	catalog_inspector.edit(_catalog_entry)
	%RemoveCatalogButton.disabled = false
	%AddCatalogButton.disabled = true
