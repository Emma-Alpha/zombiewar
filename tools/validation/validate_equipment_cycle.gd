extends SceneTree

const EquipmentController = preload("res://scripts/player/equipment_controller.gd")
const PlaceableEquipment = preload("res://scripts/player/placeable_equipment.gd")
const PlayerEquipmentLabel = preload("res://scripts/ui/player_equipment_label.gd")
const FakeEquipmentItem = preload("res://tools/validation/support/fake_equipment_item.gd")
const FakePlaceItemService = preload("res://tools/validation/support/fake_place_item_service.gd")
const OilBarrelEquipmentScene = preload("res://scenes/player/equipment/OilBarrelEquipment.tscn")
const PistolScene = preload("res://scenes/weapons/Pistol.tscn")
const RifleScene = preload("res://scenes/weapons/Rifle.tscn")
const KnifeScene = preload("res://scenes/weapons/Knife.tscn")

func _init() -> void:
	var failures: Array[String] = []
	_test_cycle_skips_empty_items(failures)
	_test_depletion_switches_to_next_item(failures)
	_test_placeable_inventory_changes_only_on_success(failures)
	_test_placeable_direction_configuration(failures)
	_test_oil_barrel_rear_direction_configuration(failures)
	_test_rifle_pickup_grants_owner_ammo_and_auto_equips(failures)
	_test_oil_barrel_pickup_caps_per_player_inventory(failures)
	_test_equipment_label_count_text_contract(failures)
	_test_demo_arena_uses_place_item_service(failures)
	if failures.is_empty():
		print("validate_equipment_cycle: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _test_cycle_skips_empty_items(failures: Array[String]) -> void:
	var controller = _build_controller([
		_build_equipment_scene("手枪", -1, true),
		_build_equipment_scene("空物品", 0, false),
		_build_equipment_scene("刀", -1, true),
	], 0)
	_expect(controller.get_current_display_name() == "手枪", "starting equipment must be selected", failures)
	_expect(controller.equip_next(), "next equipment must be selectable", failures)
	_expect(controller.get_current_display_name() == "刀", "next must skip zero-count equipment", failures)
	_expect(controller.equip_previous(), "previous equipment must be selectable", failures)
	_expect(controller.get_current_display_name() == "手枪", "previous must wrap and skip zero-count equipment", failures)
	controller.free()

func _test_depletion_switches_to_next_item(failures: Array[String]) -> void:
	var controller = _build_controller([
		_build_equipment_scene("油桶", 1, true),
		_build_equipment_scene("手枪", -1, true),
	], 0)
	var depleted_item = controller.get_current_item()
	depleted_item.consume_last()
	_expect(controller.get_current_display_name() == "手枪", "depleted current item must switch automatically", failures)
	controller.free()

func _test_placeable_inventory_changes_only_on_success(failures: Array[String]) -> void:
	var service := FakePlaceItemService.new()
	var placeable := PlaceableEquipment.new()
	var requester := CharacterBody3D.new()
	var visual_root := Node3D.new()
	var ray_origin := Marker3D.new()
	placeable.add_child(requester)
	placeable.add_child(visual_root)
	placeable.add_child(ray_origin)
	placeable.initial_count = 2
	placeable.item_scene = _build_node_scene()
	placeable.set_place_item_service(service)
	placeable.bind_context(requester, visual_root, ray_origin)
	service.next_result = false
	placeable.set_use_input(false, true, Vector3.FORWARD)
	_expect(placeable.get_remaining_count() == 2, "failed placement must not consume inventory", failures)
	service.next_result = true
	placeable.set_use_input(false, true, Vector3.FORWARD)
	_expect(placeable.get_remaining_count() == 1, "successful placement must consume exactly one item", failures)
	_expect(service.request_count == 2, "placeable must issue one request per use edge", failures)
	placeable.free()
	service.free()

func _test_placeable_direction_configuration(failures: Array[String]) -> void:
	var service := FakePlaceItemService.new()
	var placeable := PlaceableEquipment.new()
	placeable.initial_count = 2
	placeable.item_scene = _build_node_scene()
	placeable.set_place_item_service(service)
	_expect(
		"placement_direction_scale" in placeable,
		"PlaceableEquipment must expose placement_direction_scale",
		failures
	)
	placeable.set_use_input(false, true, Vector3(0.6, 0.0, -0.8))
	_expect(
		service.last_direction.is_equal_approx(Vector3(0.6, 0.0, -0.8)),
		"placeable equipment must preserve aim direction by default",
		failures
	)
	placeable.free()
	service.free()

func _test_oil_barrel_rear_direction_configuration(failures: Array[String]) -> void:
	var service := FakePlaceItemService.new()
	var oil_barrel := OilBarrelEquipmentScene.instantiate() as PlaceableEquipment
	_expect(oil_barrel != null, "OilBarrelEquipment scene must instantiate as PlaceableEquipment", failures)
	if oil_barrel == null:
		service.free()
		return
	oil_barrel.set_place_item_service(service)
	oil_barrel.add_count(1)
	oil_barrel.set_use_input(false, true, Vector3(0.6, 0.0, -0.8))
	_expect(
		service.last_direction.is_equal_approx(Vector3(-0.6, 0.0, 0.8)),
		"OilBarrelEquipment scene must reverse aim direction",
		failures
	)
	oil_barrel.free()
	service.free()

func _test_rifle_pickup_grants_owner_ammo_and_auto_equips(
	failures: Array[String]
) -> void:
	var controller = _build_controller([
		PistolScene,
		RifleScene,
		KnifeScene,
		OilBarrelEquipmentScene,
	], 0)
	_expect(
		controller.has_method(&"get_item_by_id") and
		controller.has_method(&"grant_item") and
		controller.has_method(&"add_ammo"),
		"EquipmentController must expose item pickup and ammo entry points",
		failures
	)
	if not controller.has_method(&"get_item_by_id"):
		controller.free()
		return
	var rifle = controller.call("get_item_by_id", &"rifle")
	_expect(rifle != null, "rifle must retain a stable equipment item id", failures)
	if rifle == null:
		controller.free()
		return
	_expect(not rifle.is_available(), "rifle must start unowned", failures)
	_expect(
		int(controller.call("add_ammo", &"rifle", 30)) == 0,
		"unowned rifle must reject ammo pickups",
		failures
	)
	_expect(
		bool(controller.call("grant_item", &"rifle", 400, true)),
		"rifle pickup must grant ownership or ammo",
		failures
	)
	_expect(rifle.is_available(), "rifle pickup must grant rifle ownership", failures)
	_expect(
		controller.get_current_item() == rifle,
		"auto-equipped rifle pickup must select the rifle slot",
		failures
	)
	_expect(
		rifle.get_ammo_count() == 360,
		"rifle pickup ammo must cap at the 360 round maximum",
		failures
	)
	_expect(
		not bool(controller.call("grant_item", &"rifle", 1, false)),
		"full owned rifle pickup must not report a consumed pickup",
		failures
	)
	controller.free()

func _test_oil_barrel_pickup_caps_per_player_inventory(
	failures: Array[String]
) -> void:
	var controller = _build_controller([OilBarrelEquipmentScene], 0)
	_expect(
		controller.has_method(&"get_item_by_id") and controller.has_method(&"grant_item"),
		"EquipmentController must expose item pickup lookup and grant entry points",
		failures
	)
	if not controller.has_method(&"get_item_by_id"):
		controller.free()
		return
	var oil_barrel = controller.call("get_item_by_id", &"oil_barrel")
	_expect(oil_barrel != null, "oil barrel must retain a stable equipment item id", failures)
	if oil_barrel == null:
		controller.free()
		return
	_expect(
		oil_barrel.get_remaining_count() == 0,
		"oil barrel inventory must start empty for each player",
		failures
	)
	_expect(
		bool(controller.call("grant_item", &"oil_barrel", 1000, false)),
		"oil barrel pickup must increase inventory",
		failures
	)
	_expect(
		oil_barrel.get_remaining_count() == 999,
		"oil barrel inventory must cap at 999 per player",
		failures
	)
	_expect(
		not bool(controller.call("grant_item", &"oil_barrel", 1, false)),
		"full oil barrel inventory must not report a consumed pickup",
		failures
	)
	controller.free()

func _test_equipment_label_count_text_contract(failures: Array[String]) -> void:
	var controller = _build_controller([
		PistolScene,
		RifleScene,
		KnifeScene,
		OilBarrelEquipmentScene,
	], 0)
	_expect(
		controller.has_method(&"get_current_count_text"),
		"EquipmentController must expose count text for HUD consumers",
		failures
	)
	if controller.has_method(&"get_current_count_text"):
		_expect(
			String(controller.call("get_current_count_text")) == "∞",
			"the default pistol label count must use the unlimited marker",
			failures
		)
	var rifle = controller.get_item_by_id(&"rifle")
	_expect(rifle.has_method(&"get_count_text"), "ranged weapons must expose count text", failures)
	if rifle.has_method(&"get_count_text"):
		rifle.receive_pickup(12)
		_expect(
			rifle.get_count_text() == "12",
			"finite ranged weapons must expose their current ammo as text",
			failures
		)
	var knife = controller.get_item_by_id(&"knife")
	_expect(knife.has_method(&"get_count_text"), "equipment items must expose count text", failures)
	if knife.has_method(&"get_count_text"):
		_expect(
			knife.get_count_text() == "—",
			"equipment without inventory must use the em dash marker",
			failures
		)
	var oil_barrel = controller.get_item_by_id(&"oil_barrel")
	_expect(oil_barrel.has_method(&"get_count_text"), "placeable equipment must expose count text", failures)
	if oil_barrel.has_method(&"get_count_text"):
		oil_barrel.receive_pickup(3)
		_expect(
			oil_barrel.get_count_text() == "3",
			"placeable equipment must expose its remaining inventory as text",
			failures
		)
	var label := PlayerEquipmentLabel.new()
	label.call("set_status", 0, "手枪", "∞")
	_expect(label.text == "P1 · 手枪:∞", "labels must append non-empty count text with a colon", failures)
	label.call("set_status", 3, "倒地", "")
	_expect(label.text == "P4 · 倒地", "labels must omit an empty count text", failures)
	label.free()
	controller.free()

func _test_demo_arena_uses_place_item_service(failures: Array[String]) -> void:
	var scene := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
	_expect(scene != null, "DemoArena scene must load", failures)
	if scene == null:
		return
	var arena := scene.instantiate()
	_expect(arena.get_script() != null, "DemoArena root script must compile", failures)
	_expect(arena.get_node_or_null("PlaceItemService") != null, "DemoArena must expose PlaceItemService", failures)
	arena.free()

func _build_controller(loadout: Array[PackedScene], starting_slot: int):
	var controller := EquipmentController.new()
	var wielder := CharacterBody3D.new()
	var visual_root := Node3D.new()
	var ray_origin := Marker3D.new()
	controller.add_child(wielder)
	controller.add_child(visual_root)
	controller.add_child(ray_origin)
	controller.loadout = loadout
	controller.starting_slot = starting_slot
	controller.setup(wielder, visual_root, ray_origin)
	return controller

func _build_equipment_scene(name: String, count: int, available: bool) -> PackedScene:
	var item := FakeEquipmentItem.new()
	item.display_name = name
	item.remaining_count = count
	item.available = available
	var scene := PackedScene.new()
	scene.pack(item)
	item.free()
	return scene

func _build_node_scene() -> PackedScene:
	var node := Node3D.new()
	var scene := PackedScene.new()
	scene.pack(node)
	node.free()
	return scene

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
