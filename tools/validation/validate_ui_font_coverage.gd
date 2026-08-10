extends SceneTree

## UI 字体字形覆盖检查。
##
## 存在的理由是一个真实发生过的故障：`NotoSansSC-UI.ttf` 曾是一份只裁了
## 「当时用到的字」的子集（127 个字符），于是「单人游戏」「本地多人」在
## **Web 导出**里显示成豆腐块——而桌面端因为 `allow_system_fallback=true`
## 会回退到系统中文字体，看起来一切正常。
##
## 也就是说：这类缺字在开发者的机器上永远复现不了，只在玩家的浏览器里出现。
## 没有这个检查，下一次有人加一句新文案就会重蹈覆辙，而且要等到上线才发现。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_ui_font_coverage.gd

const UI_FONT_PATH := "res://assets/fonts/NotoSansSC-UI.ttf"
const SCAN_ROOTS: Array[String] = ["res://scripts", "res://scenes", "res://resources"]
const SCAN_EXTENSIONS: Array[String] = ["gd", "tscn", "tres"]
## 报告里最多列出多少个缺失字符，超出的只报数量。
const MAX_REPORTED := 40

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var font := load(UI_FONT_PATH) as FontFile
	if font == null:
		printerr("validate_ui_font_coverage: 无法加载 %s" % UI_FONT_PATH)
		quit(1)
		return

	var occurrences := {}
	for root in SCAN_ROOTS:
		_scan_directory(root, occurrences)

	var missing: Array[String] = []
	for character in occurrences.keys():
		if not font.has_char(character.unicode_at(0)):
			missing.append(character)
	missing.sort()

	if missing.is_empty():
		printerr("")  # 保持输出干净
		print(
			"validate_ui_font_coverage: PASS（%d 个非 ASCII 字符全部有字形）"
			% occurrences.size()
		)
		quit(0)
		return

	printerr("validate_ui_font_coverage: 以下字符在 UI 字体里没有字形，")
	printerr("Web 导出会显示成豆腐块（桌面端会被系统字体回退掩盖）：")
	var shown := missing.slice(0, MAX_REPORTED)
	printerr("  缺失 %d 个：%s" % [missing.size(), "".join(shown)])
	for character in shown:
		var where: Array = occurrences[character]
		printerr("    '%s' 出现在 %s" % [character, ", ".join(where.slice(0, 3))])
	printerr("修复：用完整的 Noto Sans SC 重新裁剪子集，字符集要覆盖常用字，")
	printerr("而不是只覆盖「当前用到的字」——后者正是这个故障的成因。")
	quit(1)

func _scan_directory(path: String, occurrences: Dictionary) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = directory.get_next()
			continue
		var full_path := path.path_join(entry)
		if directory.current_is_dir():
			_scan_directory(full_path, occurrences)
		elif entry.get_extension() in SCAN_EXTENSIONS:
			_scan_file(full_path, occurrences)
		entry = directory.get_next()
	directory.list_dir_end()

## 只看字符串字面量。注释里的中文不会被渲染，把它们算进来会逼着字体
## 收录一堆永远不显示的字，白白撑大包体。
func _scan_file(path: String, occurrences: Dictionary) -> void:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return
	var regex := RegEx.new()
	regex.compile("\"([^\"\\\\\\n]*)\"")
	var file_name := path.get_file()
	for found in regex.search_all(text):
		for character in found.get_string(1):
			if character.unicode_at(0) <= 0x2000:
				continue
			if not occurrences.has(character):
				occurrences[character] = []
			var where: Array = occurrences[character]
			if not where.has(file_name):
				where.append(file_name)
