extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const MENU_SCENE = preload("res://scenes/menu/MainMenu.tscn")
const TEXT_CONTROLS: Array[NodePath] = [
	NodePath("MenuLayer/MenuRoot/LeftColumn/Subtitle"),
	NodePath("MenuLayer/MenuRoot/LeftColumn/Actions/StartButton"),
	NodePath("MenuLayer/MenuRoot/LeftColumn/Actions/QuitButton"),
	NodePath("MenuLayer/MenuRoot/FooterHint"),
	NodePath("MenuLayer/MenuRoot/ExitDialog/DialogPanel/DialogMargin/DialogContent/DialogTitle"),
	NodePath("MenuLayer/MenuRoot/ExitDialog/DialogPanel/DialogMargin/DialogContent/DialogMessage"),
	NodePath("MenuLayer/MenuRoot/ExitDialog/DialogPanel/DialogMargin/DialogContent/DialogActions/CancelExitButton"),
	NodePath("MenuLayer/MenuRoot/ExitDialog/DialogPanel/DialogMargin/DialogContent/DialogActions/ConfirmExitButton"),
]

func run() -> Array[String]:
	var failures: Array[String] = []
	var menu := MENU_SCENE.instantiate()
	for control_path in TEXT_CONTROLS:
		var control := menu.get_node_or_null(control_path) as Control
		_append(failures, Assertions.expect_true(control != null, "Menu text control exists: %s" % control_path))
		if control == null:
			continue
		var font := control.get_theme_font(&"font")
		_append(failures, Assertions.expect_true(font != null, "Menu text control has a font: %s" % control_path))
		if font == null:
			continue
		for glyph in control.text:
			var codepoint: int = glyph.unicode_at(0)
			if codepoint < 0x4E00 or codepoint > 0x9FFF:
				continue
			_append(failures, Assertions.expect_true(
				font.has_char(codepoint),
				"Menu font includes CJK glyph %s for %s" % [glyph, control_path]
			))
	menu.queue_free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
