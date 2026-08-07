extends SceneTree

const EquipmentController = preload("res://scripts/player/equipment_controller.gd")
const PlaceableEquipment = preload("res://scripts/player/placeable_equipment.gd")
const FakeEquipmentItem = preload("res://tools/validation/support/fake_equipment_item.gd")
const FakePlaceItemService = preload("res://tools/validation/support/fake_place_item_service.gd")

func _init() -> void:
	var failures: Array[String] = []
	_test_cycle_skips_empty_items(failures)
	_test_depletion_switches_to_next_item(failures)
	_test_placeable_inventory_changes_only_on_success(failures)
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
