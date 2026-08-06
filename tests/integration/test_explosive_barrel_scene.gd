extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ExplosionResolver = preload("res://scripts/combat/explosion_resolver.gd")
const BARREL_SCENE := preload("res://scenes/props/ExplosiveBarrel.tscn")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const ZOMBIE_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")
const ARENA_SCENE := preload("res://scenes/gameplay/DemoArena.tscn")
const ZOMBIE_HITBOX_SCRIPT := preload("res://scripts/combat/zombie_hitbox.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_damage_dedup_and_stacking(failures)
	_test_world_cover_blocks_damage(failures)
	_test_explosion_chains_only_inside_radius(failures)
	_test_melee_and_arena_contract(failures)
	return failures

func _test_damage_dedup_and_stacking(failures: Array[String]) -> void:
	var host := Node3D.new()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var zombie := ZOMBIE_SCENE.instantiate() as ZombieTarget
	player.position = Vector3(-2.0, 0.0, 0.0)
	zombie.position = Vector3(2.0, 0.0, 0.0)
	player.set_physics_process(false)
	zombie.set_physics_process(false)
	_add_duplicate_zombie_hitbox(zombie)
	host.add_child(player)
	host.add_child(zombie)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(host)
	player.force_update_transform()
	zombie.force_update_transform()

	ExplosionResolver.resolve(
		player.get_world_3d(),
		Vector3.ZERO,
		5.0,
		10.0,
		10.0,
		null
	)
	_append(failures, Assertions.expect_float_near(
		player.health.current,
		90.0,
		0.0001,
		"One explosion damages the player once"
	))
	_append(failures, Assertions.expect_float_near(
		zombie.health.current,
		40.0,
		0.0001,
		"One explosion deduplicates multiple zombie hitboxes"
	))

	ExplosionResolver.resolve(
		player.get_world_3d(),
		Vector3.ZERO,
		5.0,
		10.0,
		10.0,
		null
	)
	_append(failures, Assertions.expect_float_near(
		player.health.current,
		80.0,
		0.0001,
		"Separate explosions stack player damage"
	))
	_append(failures, Assertions.expect_float_near(
		zombie.health.current,
		30.0,
		0.0001,
		"Separate explosions stack zombie damage"
	))
	host.free()

func _test_world_cover_blocks_damage(failures: Array[String]) -> void:
	var host := Node3D.new()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	player.position = Vector3(3.0, 0.0, 0.0)
	player.set_physics_process(false)
	var wall := StaticBody3D.new()
	wall.position = Vector3(1.5, 0.9, 0.0)
	wall.collision_layer = 1
	wall.collision_mask = 0
	var wall_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.4, 2.2, 2.0)
	wall_shape.shape = box
	wall.add_child(wall_shape)
	host.add_child(player)
	host.add_child(wall)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(host)
	player.force_update_transform()
	wall.force_update_transform()

	ExplosionResolver.resolve(
		player.get_world_3d(),
		Vector3(0.0, 0.9, 0.0),
		5.0,
		80.0,
		20.0,
		null
	)
	_append(failures, Assertions.expect_float_near(
		player.health.current,
		100.0,
		0.0001,
		"Layer-one world cover blocks explosion damage"
	))
	host.free()

func _test_explosion_chains_only_inside_radius(failures: Array[String]) -> void:
	var host := Node3D.new()
	var source := BARREL_SCENE.instantiate() as ExplosiveBarrel
	var near_barrel := BARREL_SCENE.instantiate() as ExplosiveBarrel
	var far_barrel := BARREL_SCENE.instantiate() as ExplosiveBarrel
	source.position = Vector3.ZERO
	near_barrel.position = Vector3(3.0, 0.0, 0.0)
	far_barrel.position = Vector3(8.0, 0.0, 0.0)
	near_barrel.chain_delay_seconds = 0.0
	far_barrel.chain_delay_seconds = 0.0
	host.add_child(source)
	host.add_child(near_barrel)
	host.add_child(far_barrel)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(host)
	source.force_update_transform()
	near_barrel.force_update_transform()
	far_barrel.force_update_transform()

	ExplosionResolver.resolve(
		source.get_world_3d(),
		source.get_explosion_aim_point(),
		4.5,
		80.0,
		20.0,
		source
	)
	_append(failures, Assertions.expect_equal(
		near_barrel.get_state(),
		ExplosiveBarrel.State.EXPLODING,
		"Explosion locks a nearby barrel for a chain reaction"
	))
	_append(failures, Assertions.expect_equal(
		far_barrel.get_state(),
		ExplosiveBarrel.State.INTACT,
		"Explosion leaves an out-of-range barrel intact"
	))
	host.free()

func _test_melee_and_arena_contract(failures: Array[String]) -> void:
	var barrel := BARREL_SCENE.instantiate() as ExplosiveBarrel
	_append(failures, Assertions.expect_true(
		not barrel.is_in_group(&"damageable_targets"),
		"Explosive barrel stays outside melee damageable targets"
	))
	var has_melee_area := false
	for child in barrel.get_children():
		if child is Area3D and ((child as Area3D).collision_layer & 4) != 0:
			has_melee_area = true
	_append(failures, Assertions.expect_true(
		not has_melee_area,
		"Explosive barrel exposes no melee-query hit area"
	))
	barrel.free()

	var arena := ARENA_SCENE.instantiate()
	var barrels_root := arena.get_node_or_null(
		"World/Props/ExplosiveBarrels"
	)
	var barrels: Array[Node] = []
	if barrels_root != null:
		barrels.assign(barrels_root.get_children())
	_append(failures, Assertions.expect_equal(
		barrels.size(),
		3,
		"Demo arena contains the three planned explosive barrels"
	))
	if barrels.size() == 3:
		var chain_a := barrels_root.get_node("ChainA") as ExplosiveBarrel
		var chain_b := barrels_root.get_node("ChainB") as ExplosiveBarrel
		var solo := barrels_root.get_node("Solo") as ExplosiveBarrel
		_append(failures, Assertions.expect_true(
			_planar_distance(chain_a.position, chain_b.position) < 4.5,
			"Demo arena chain barrels sit inside blast radius"
		))
		_append(failures, Assertions.expect_true(
			_planar_distance(solo.position, chain_a.position) > 4.5 and
				_planar_distance(solo.position, chain_b.position) > 4.5,
			"Demo arena solo barrel sits outside both chain blasts"
		))
		var navigation_callback := Callable(
			arena,
			"_on_barrel_navigation_geometry_changed"
		)
		for placed_barrel in barrels:
			_append(failures, Assertions.expect_true(
				placed_barrel.is_in_group(&"navigation_source") and
				placed_barrel.navigation_geometry_changed.is_connected(
					navigation_callback
				),
				"Arena barrel is a wired navigation source: %s" % placed_barrel.name
			))
	arena.free()

func _add_duplicate_zombie_hitbox(zombie: ZombieTarget) -> void:
	var hitboxes := zombie.get_node("Hitboxes") as Node3D
	var duplicate := Area3D.new()
	duplicate.name = "DuplicateBodyHitbox"
	duplicate.position = Vector3(0.0, 1.1, 0.0)
	duplicate.collision_layer = 4
	duplicate.collision_mask = 0
	duplicate.monitoring = false
	duplicate.set_script(ZOMBIE_HITBOX_SCRIPT)
	var shape_node := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 1.1
	shape.height = 2.2
	shape_node.shape = shape
	duplicate.add_child(shape_node)
	hitboxes.add_child(duplicate)

func _planar_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x, first.z).distance_to(Vector2(second.x, second.z))

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
