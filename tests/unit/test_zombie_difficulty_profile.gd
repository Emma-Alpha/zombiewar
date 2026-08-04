extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ZombieDifficultyProfile = preload("res://scripts/gameplay/zombie_difficulty_profile.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var easy := load("res://resources/difficulty/zombie_easy.tres")
	var normal := load("res://resources/difficulty/zombie_normal.tres")
	var hard := load("res://resources/difficulty/zombie_hard.tres")
	_append(failures, Assertions.expect_true(
		easy is ZombieDifficultyProfile and normal is ZombieDifficultyProfile and hard is ZombieDifficultyProfile,
		"All zombie difficulty resources load as ZombieDifficultyProfile"
	))
	if easy is ZombieDifficultyProfile and normal is ZombieDifficultyProfile and hard is ZombieDifficultyProfile:
		_append(failures, Assertions.expect_float_near(easy.perception_move_speed, 0.90, 0.0001, "Easy perception speed"))
		_append(failures, Assertions.expect_float_near(normal.perception_move_speed, 1.30, 0.0001, "Normal perception speed"))
		_append(failures, Assertions.expect_float_near(hard.perception_move_speed, 1.80, 0.0001, "Hard perception speed"))
		_append(failures, Assertions.expect_true(
			easy.perception_move_speed < normal.perception_move_speed and normal.perception_move_speed < hard.perception_move_speed,
			"Difficulty increases only perceived movement pressure"
		))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
