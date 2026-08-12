extends SceneTree

const INVENTORY_SLOT_PATH := "res://scripts/gameplay/inventory/inventory_slot.gd"
const INVENTORY_PROFILE_PATH := "res://scripts/gameplay/inventory/inventory_profile.gd"
const INVENTORY_PROFILES_PATH := "res://resources/inventory/inventory_profiles.tres"
const PICKUP_DEFINITION_PATH := "res://scripts/gameplay/pickup_definition.gd"
const MAP_RUNTIME_PATH := "res://scripts/gameplay/map/game_map_runtime.gd"
const FAKE_OWNER_PATH := "res://tools/validation/support/fake_inventory_owner.gd"
const WEAPON_MOD_TABLE_PATH := "res://scripts/sim/weapon_mod_table.gd"
const SIM_WORLD_PATH := "res://scripts/sim/sim_world.gd"
const PICKUP_DIRECTORY := "res://resources/pickups"
const MOD_DIRECTORY := "res://resources/mods"
const WEAPON_DIRECTORY := "res://resources/weapons"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for path in [
		INVENTORY_SLOT_PATH,
		INVENTORY_PROFILE_PATH,
		INVENTORY_PROFILES_PATH,
		PICKUP_DEFINITION_PATH,
		MAP_RUNTIME_PATH,
		FAKE_OWNER_PATH,
		WEAPON_MOD_TABLE_PATH,
		SIM_WORLD_PATH,
	]:
		_check("required inventory path must exist: %s" % path, ResourceLoader.exists(path))
	if not failures.is_empty():
		_finish()
		return

	var inventory_slot_script := load(INVENTORY_SLOT_PATH) as Script
	var inventory_profile_script := load(INVENTORY_PROFILE_PATH) as Script
	var pickup_definition_script := load(PICKUP_DEFINITION_PATH) as Script
	var map_runtime_script := load(MAP_RUNTIME_PATH) as Script
	var fake_owner_script := load(FAKE_OWNER_PATH) as Script
	var mod_table_script := load(WEAPON_MOD_TABLE_PATH) as Script
	var sim_world_script := load(SIM_WORLD_PATH) as Script
	var catalog := load(INVENTORY_PROFILES_PATH)
	_check("InventorySlot script must load", inventory_slot_script != null)
	_check("InventoryProfile script must load", inventory_profile_script != null)
	_check("PickupDefinition script must load", pickup_definition_script != null)
	_check("GameMapRuntime script must load", map_runtime_script != null)
	_check("fake inventory owner script must load", fake_owner_script != null)
	_check("WeaponModTable script must load", mod_table_script != null)
	_check("SimWorld script must load", sim_world_script != null)
	_check("inventory profile catalog must load", catalog != null)
	if not failures.is_empty():
		_finish()
		return

	_test_slot_contract(inventory_slot_script, fake_owner_script)
	_test_profile_catalog(catalog, inventory_profile_script, mod_table_script)
	_test_pickup_metadata(catalog, pickup_definition_script, inventory_profile_script, mod_table_script)
	_test_map_runtime_contract(map_runtime_script, catalog)
	_test_sim_inventory_acceptance(sim_world_script)
	_finish()


func _test_slot_contract(slot_script: Script, fake_owner_script: Script) -> void:
	_check("InventorySlot must expose SLOT_COUNT", "SLOT_COUNT" in slot_script)
	if not ("SLOT_COUNT" in slot_script):
		return
	_check("inventory must support exactly 12 slots", int(slot_script.SLOT_COUNT) == 12)
	var slot = slot_script.new()
	_check("InventorySlot must expose profile_index", "profile_index" in slot)
	_check("InventorySlot must expose amount", "amount" in slot)
	_check("InventorySlot must expose is_empty()", slot.has_method(&"is_empty"))
	_check("InventorySlot must expose clear()", slot.has_method(&"clear"))
	if not ("profile_index" in slot) or not ("amount" in slot):
		return
	_check("new inventory slot must be empty", bool(slot.is_empty()))
	slot.profile_index = 4
	slot.amount = 2
	_check("populated inventory slot must not be empty", not bool(slot.is_empty()))
	slot.clear()
	_check("clear must reset profile_index", slot.profile_index == -1)
	_check("clear must reset amount", slot.amount == 0)
	var owner = fake_owner_script.new()
	owner.build_slots(slot_script, int(slot_script.SLOT_COUNT))
	_check("fake owner must construct exactly 12 mutable slots", owner.slots.size() == 12)


func _test_profile_catalog(catalog, profile_script: Script, mod_table_script: Script) -> void:
	_check("inventory profile catalog must expose profiles", "profiles" in catalog)
	if not ("profiles" in catalog):
		return
	var profiles: Array = catalog.profiles
	_check("5x4 atlas must have no reserved cell", profiles.size() == 20)
	var ids: Dictionary = {}
	var regions: Dictionary = {}
	var weapon_profiles: Dictionary = {}
	var ammo_profiles: Dictionary = {}
	var mod_profiles: Dictionary = {}
	var oil_profiles := 0
	for profile in profiles:
		_check("catalog entries must be InventoryProfile resources", profile != null)
		if profile == null:
			continue
		_check("profile id must not be empty", not profile.profile_id.is_empty())
		_check("profile id must be unique: %s" % profile.profile_id, not ids.has(profile.profile_id))
		ids[profile.profile_id] = true
		_check(
			"profile '%s' category must be valid" % profile.profile_id,
			profile.category >= profile_script.Category.WEAPON
			and profile.category <= profile_script.Category.WEAPON_MOD
		)
		_check("profile '%s' display name must not be empty" % profile.profile_id, not profile.display_name.is_empty())
		_check("profile '%s' icon region must be non-zero" % profile.profile_id, profile.icon_region.size.x > 0.0 and profile.icon_region.size.y > 0.0)
		_check(
			"profile '%s' icon region must fit the 5x4 atlas" % profile.profile_id,
			profile_script.is_icon_region_inside_atlas(profile.icon_region)
		)
		_check(
			"profile '%s' icon region must not be shared" % profile.profile_id,
			not regions.has(profile.icon_region)
		)
		regions[profile.icon_region] = true
		match profile.category:
			profile_script.Category.WEAPON:
				weapon_profiles[profile.weapon_id] = profile
			profile_script.Category.AMMO:
				ammo_profiles[profile.weapon_id] = profile
			profile_script.Category.OIL:
				oil_profiles += 1
			profile_script.Category.WEAPON_MOD:
				mod_profiles[profile.mod_id] = profile
	_check("knife must occupy atlas row 0", ids.has(&"weapon_knife") and profiles[0].icon_region.position == Vector2.ZERO)
	_check("oil must occupy atlas row 1", ids.has(&"oil_barrel") and regions.has(Rect2(Vector2(256, 64), Vector2(64, 64))))
	_check("catalog must have one oil profile", oil_profiles == 1)
	_check("catalog must cover every weapon", weapon_profiles.size() == 5)
	_check("catalog must cover every ammunition identity", ammo_profiles.size() == 4)
	_check("catalog must cover all ten weapon mods", mod_profiles.size() == int(mod_table_script.COUNT))
	for mod_index in range(int(mod_table_script.COUNT)):
		var mod_id: StringName = mod_table_script.MOD_IDS[mod_index]
		_check("profile missing mod '%s'" % mod_id, mod_profiles.has(mod_id))
		if mod_profiles.has(mod_id):
			_check(
				"mod '%s' max stack must match WeaponModTable.MAX_STACKS" % mod_id,
				mod_profiles[mod_id].max_stack == mod_table_script.MAX_STACKS[mod_index]
			)
	var weapons := _load_weapon_definitions()
	for weapon_id in weapons:
		var definition = weapons[weapon_id]
		_check("profile missing weapon '%s'" % weapon_id, weapon_profiles.has(weapon_id))
		if definition is RangedWeaponDefinition:
			_check("profile missing ammo identity '%s'" % weapon_id, ammo_profiles.has(weapon_id))
			if ammo_profiles.has(weapon_id):
				_check(
					"ammo '%s' max stack must match RangedWeaponDefinition.max_ammo" % weapon_id,
					ammo_profiles[weapon_id].max_stack == definition.max_ammo
				)


func _test_pickup_metadata(catalog, pickup_definition_script: Script, profile_script: Script, mod_table_script: Script) -> void:
	var profile_by_id: Dictionary = {}
	for profile in catalog.profiles:
		profile_by_id[profile.profile_id] = profile
	for path in _collect_tres_paths(PICKUP_DIRECTORY) + _collect_tres_paths(MOD_DIRECTORY):
		var definition = load(path)
		_check("pickup metadata resource must load: %s" % path, definition != null)
		if definition == null:
			continue
		_check("%s must expose get_inventory_category()" % path, definition.has_method(&"get_inventory_category"))
		_check("%s must expose get_inventory_key()" % path, definition.has_method(&"get_inventory_key"))
		_check("%s must expose get_inventory_max_stack()" % path, definition.has_method(&"get_inventory_max_stack"))
		if not definition.has_method(&"get_inventory_key"):
			continue
		var key: StringName = definition.get_inventory_key()
		_check("%s must have a stable inventory key" % path, not key.is_empty())
		_check("%s inventory key must resolve without fallback" % path, profile_by_id.has(key))
		if not profile_by_id.has(key):
			continue
		var profile = profile_by_id[key]
		_check(
			"%s category must match profile '%s'" % [path, key],
			definition.get_inventory_category() == profile.category
		)
		_check(
			"%s max stack must match profile '%s'" % [path, key],
			definition.get_inventory_max_stack() == profile.max_stack
		)
		if definition.get_inventory_category() == profile_script.Category.WEAPON_MOD:
			var mod_index = mod_table_script.mod_index_from_id(definition.inventory_mod_id)
			_check("%s must associate a known weapon mod" % path, mod_index >= 0)
			_check("%s must map to its mod profile" % path, profile.mod_id == definition.inventory_mod_id)
		elif definition.get_inventory_category() == profile_script.Category.AMMO:
			_check("%s must associate its weapon" % path, profile.weapon_id == definition.inventory_weapon_id)
		elif definition.get_inventory_category() == profile_script.Category.WEAPON:
			_check("%s must associate its weapon" % path, profile.weapon_id == definition.inventory_weapon_id)
		elif definition.get_inventory_category() == profile_script.Category.OIL:
			_check("%s must use the oil profile id" % path, key == &"oil_barrel")


func _test_map_runtime_contract(map_runtime_script: Script, catalog: InventoryProfile) -> void:
	var runtime = map_runtime_script.new()
	_check("GameMapRuntime must expose inventory_profiles()", runtime.has_method(&"inventory_profiles"))
	_check("GameMapRuntime must expose inventory_profile_index_for()", runtime.has_method(&"inventory_profile_index_for"))
	var catalog_errors := PackedStringArray()
	var no_rewards: Array[PickupDefinition] = []
	runtime._compile_inventory_profiles(no_rewards, catalog_errors)
	_check("unmodified inventory profile catalog must compile without validation errors", catalog_errors.is_empty())
	if runtime.has_method(&"inventory_profile_index_for"):
		_check(
			"unknown inventory reward profile must not fall back to a default",
			runtime.inventory_profile_index_for(9999) == -1
		)
	_assert_map_compile_rejects_catalog_field(
		runtime, catalog, &"weapon_smg", &"category", 99,
		"invalid inventory profile category"
	)
	_assert_map_compile_rejects_catalog_field(
		runtime, catalog, &"weapon_smg", &"max_stack", 0,
		"inventory profile max stack must be positive"
	)
	_assert_map_compile_rejects_catalog_field(
		runtime, catalog, &"weapon_smg", &"icon_region",
		Rect2(Vector2(1, 0), Vector2(64, 64)),
		"inventory profile icon region must be a single atlas cell"
	)
	_assert_map_compile_rejects_catalog_field(
		runtime, catalog, &"weapon_smg", &"icon_region",
		Rect2(Vector2(320, 0), Vector2(64, 64)),
		"inventory profile icon region must be a single atlas cell"
	)
	_assert_map_compile_rejects_catalog_field(
		runtime, catalog, &"weapon_smg", &"weapon_id", &"unknown_weapon",
		"inventory profile references unknown weapon id"
	)
	_assert_map_compile_rejects_catalog_field(
		runtime, catalog, &"mod_damage", &"mod_id", &"unknown_mod",
		"inventory profile references unknown weapon mod id"
	)
	_assert_map_compile_rejects_catalog_field(
		runtime, catalog, &"ammo_smg", &"max_stack", 1,
		"inventory ammo max stack must match weapon max_ammo"
	)
	_assert_map_compile_rejects_catalog_field(
		runtime, catalog, &"ammo_smg", &"max_stack", 0,
		"inventory profile max stack must be positive"
	)
	_assert_map_compile_rejects_catalog_field(
		runtime, catalog, &"mod_damage", &"max_stack", 1,
		"inventory weapon mod max stack must match WeaponModTable"
	)
	var compiled: Dictionary = runtime._compile_inventory_profiles(no_rewards, catalog_errors)
	runtime._inventory_profiles = compiled["profiles"]
	_check(
		"GameMapRuntime must expose stable simulation inventory dictionaries",
		runtime.has_method(&"inventory_profile_dictionaries")
	)
	if runtime.has_method(&"inventory_profile_dictionaries"):
		var dictionaries: Array[Dictionary] = runtime.inventory_profile_dictionaries()
		_check(
			"simulation dictionaries must preserve the stable compiled profile count",
			dictionaries.size() == (compiled["profiles"] as Array).size()
		)
		if not dictionaries.is_empty():
			_check(
				"simulation dictionaries must carry category, capacity, weapon, and mod identities",
				dictionaries[0].has("category")
				and dictionaries[0].has("max_stack")
				and dictionaries[0].has("weapon_id")
				and dictionaries[0].has("mod_id")
			)


## Catches capacity checks that mutate a slot, select a later empty slot, or let a
## chest disappear before the simulation has accepted its reward.
func _test_sim_inventory_acceptance(sim_world_script: Script) -> void:
	var world = sim_world_script.new()
	world.configure(Vector2(-4.5, -4.5), 1.0, 9, 9)
	var profiles: Array[Dictionary] = [
		{"category": 0, "max_stack": 1, "weapon_id": &"smg", "mod_id": -1},
		{"category": 1, "max_stack": 10, "weapon_id": &"smg", "mod_id": -1},
		{"category": 2, "max_stack": 3, "weapon_id": &"", "mod_id": -1},
		{"category": 3, "max_stack": 2, "weapon_id": &"", "mod_id": 0},
	]
	# reward 0=SMG weapon, 1=SMG ammo, 2=oil, 3=damage mod.
	world.configure_inventory_profiles(profiles, PackedInt32Array([0, 1, 2, 3]))
	world.reset(1)
	_check("empty inventory must accept a weapon reward", world.can_accept_reward(0, 0, 4))
	var weapon_result: Dictionary = world.accept_reward(0, 0, 4)
	_check("first weapon reward must be accepted", bool(weapon_result.get("accepted", false)))
	_check("first weapon must use the lowest empty slot", world.get_inventory_slot_profile(0, 0) == 0)
	_check("weapon slots must store one owned weapon", world.get_inventory_slot_amount(0, 0) == 1)
	_check("first weapon must create matching finite ammo", world.get_inventory_slot_profile(0, 1) == 1)
	_check("first weapon must store its starting ammo", world.get_inventory_slot_amount(0, 1) == 4)
	var duplicate_weapon: Dictionary = world.accept_reward(0, 0, 6)
	_check("duplicate weapon must become matching finite ammo", bool(duplicate_weapon.get("accepted", false)))
	_check("duplicate weapon must merge into the existing ammo slot", world.get_inventory_slot_profile(0, 1) == 1)
	_check("duplicate weapon must add its reward amount to ammo", world.get_inventory_slot_amount(0, 1) == 10)
	world.accept_reward(0, 1, 4)
	_check("ammo must merge before selecting a new slot", world.get_inventory_slot_amount(0, 1) == 10)
	_check("full finite ammo must reject further rewards", not world.can_accept_reward(0, 1, 1))
	var oil_result: Dictionary = world.accept_reward(0, 2, 2)
	_check("oil must be accepted into its own stack", bool(oil_result.get("accepted", false)))
	world.accept_reward(0, 2, 2)
	_check("oil must clamp at its finite stack limit", world.get_inventory_slot_amount(0, 2) == 3)
	var mod_result: Dictionary = world.accept_reward(0, 3, 1)
	_check("weapon mod must be accepted", bool(mod_result.get("accepted", false)))
	_check("weapon mod must update its simulation level", world.get_weapon_mod_level(0, 0) == 1)
	_check("weapon mod inventory amount must mirror its level", world.get_inventory_slot_amount(0, 3) == 1)
	world.accept_reward(0, 3, 1)
	_check("weapon mod must clamp at its configured level", world.get_weapon_mod_level(0, 0) == 2)
	_check("full weapon mod must reject further rewards", not world.can_accept_reward(0, 3, 1))

	var rejected_world = sim_world_script.new()
	rejected_world.configure(Vector2(-4.5, -4.5), 1.0, 9, 9)
	rejected_world.configure_inventory_profiles(profiles, PackedInt32Array([0, 1, 2, 3]))
	rejected_world.reset(2)
	for inventory_slot in range(12):
		rejected_world.inventory_slot_profile[inventory_slot] = 0
		rejected_world.inventory_slot_amount[inventory_slot] = 1
	var chest_position := Vector2.ZERO
	var chest_id: int = rejected_world.spawn_chest(
		chest_position, 2, 1, -1,
		chest_position - Vector2(0.24, 0.18),
		chest_position + Vector2(0.24, 0.18),
		1.15
	)
	var chest_cell: Vector2i = rejected_world.get_grid().world_to_cell(chest_position)
	rejected_world.set_player_snapshot(0, chest_position, true, true)
	rejected_world.step_tick()
	_check(
		"rejected chest reward must keep the chest active",
		rejected_world.get_chest_state(rejected_world.index_of_chest(chest_id)) == 0
	)
	_check("rejected chest reward must keep its blocker", rejected_world.get_grid().is_blocked(chest_cell))
	_check(
		"rejected chest must emit deterministic inventory feedback",
		not rejected_world.tick_inventory_feedback.is_empty()
	)


func _assert_map_compile_rejects_catalog_field(
	runtime,
	catalog: InventoryProfile,
	profile_id: StringName,
	field: StringName,
	invalid_value,
	expected_error: String
) -> void:
	var profile := _inventory_profile_by_id(catalog, profile_id)
	_check("catalog must contain profile '%s' for map compiler validation" % profile_id, profile != null)
	if profile == null:
		return
	var original_value = profile.get(field)
	profile.set(field, invalid_value)
	var errors := PackedStringArray()
	var no_rewards: Array[PickupDefinition] = []
	runtime._compile_inventory_profiles(no_rewards, errors)
	_check(
		"map compilation must reject %s on '%s'" % [field, profile_id],
		_contains_error(errors, expected_error)
	)
	profile.set(field, original_value)


func _inventory_profile_by_id(catalog: InventoryProfile, profile_id: StringName) -> InventoryProfile:
	for profile in catalog.profiles:
		if profile != null and profile.profile_id == profile_id:
			return profile
	return null


func _contains_error(errors: PackedStringArray, expected_error: String) -> bool:
	for error in errors:
		if error.contains(expected_error):
			return true
	return false


func _load_weapon_definitions() -> Dictionary:
	var result: Dictionary = {}
	for path in _collect_tres_paths(WEAPON_DIRECTORY):
		var definition = load(path)
		if definition != null and "weapon_id" in definition:
			result[definition.weapon_id] = definition
	return result


func _collect_tres_paths(directory_path: String) -> Array[String]:
	var paths: Array[String] = []
	var directory := DirAccess.open(directory_path)
	if directory == null:
		return paths
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if not directory.current_is_dir() and entry.get_extension() == "tres":
			paths.append(directory_path.path_join(entry))
		entry = directory.get_next()
	directory.list_dir_end()
	paths.sort()
	return paths


func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("validate_inventory: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
