extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PREWARMER_PATH := "res://scripts/fx/combat_fx_prewarmer.gd"
const ARENA_PATH := "res://scenes/gameplay/DemoArena.tscn"
const EXPECTED_FX_PATHS: Array[String] = [
	"res://scenes/fx/BarrelDamageSmoke.tscn",
	"res://scenes/fx/BarrelExplosion.tscn",
	"res://scenes/fx/BloodImpact.tscn",
	"res://scenes/fx/GroundBloodSplat.tscn",
	"res://scenes/fx/MuzzleFlash.tscn",
	"res://scenes/fx/ShotTracer.tscn",
]

func run() -> Array[String]:
	var failures: Array[String] = []
	var prewarmer_script := load(PREWARMER_PATH) as Script
	_append(failures, Assertions.expect_true(
		prewarmer_script != null,
		"Combat FX prewarmer script loads"
	))
	if prewarmer_script == null:
		return failures

	var prewarmer: Object = prewarmer_script.new()
	var discovered: Array[String] = prewarmer.call(
		"discover_warmup_scene_paths"
	)
	for expected_path in EXPECTED_FX_PATHS:
		_append(failures, Assertions.expect_true(
			expected_path in discovered,
			"Combat FX prewarmer discovers %s" % expected_path
		))
		var packed := load(expected_path) as PackedScene
		var effect: Node = packed.instantiate() if packed != null else null
		_append(failures, Assertions.expect_true(
			effect != null and
				effect.has_method("warmup_for_render") and
				effect.has_method("finish_render_warmup"),
			"Warmable FX exposes the shared lifecycle: %s" % expected_path
		))
		if effect != null:
			effect.free()
	prewarmer.free()

	var arena_packed := load(ARENA_PATH) as PackedScene
	var arena: Node = arena_packed.instantiate() if arena_packed != null else null
	_append(failures, Assertions.expect_true(
		arena != null and
			arena.get_node_or_null("CombatFxPrewarmer") != null and
			arena.get_node_or_null("WarmupLayer/Overlay") is ColorRect,
		"Demo arena owns the combat FX prewarmer and loading overlay"
	))
	if arena != null:
		var layer := arena.get_node_or_null("WarmupLayer") as CanvasLayer
		var overlay := arena.get_node_or_null(
			"WarmupLayer/Overlay"
		) as ColorRect
		_append(failures, Assertions.expect_true(
			layer != null and layer.layer >= 100 and
				overlay != null and overlay.visible and overlay.color.a >= 0.99,
			"Warmup overlay is opaque and above gameplay UI by default"
		))
		arena.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
