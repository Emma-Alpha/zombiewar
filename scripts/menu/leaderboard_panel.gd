extends Node3D
class_name LeaderboardPanel

## 排行榜面板：队伍波次榜与个人击杀榜。
##
## 「未认证」角标读的是服务端返回的 `authenticated` 字段，不是「我拿到令牌了」。
## 匿名设备身份换来的令牌能证明的只有一件事：持有者调用过一次 /api/auth/anon。
## 把它当成认证来展示，是这套东西唯一真正会骗到人的地方。

const PAGE_SIZE := 20

@export_file("*.tscn") var main_menu_scene_path := "res://scenes/menu/MainMenu.tscn"

@onready var status_label: Label = %StatusLabel
@onready var entries_label: RichTextLabel = %EntriesLabel
@onready var team_button: Button = %TeamBoardButton
@onready var kills_button: Button = %KillsBoardButton
@onready var previous_button: Button = %PreviousPageButton
@onready var next_button: Button = %NextPageButton

var current_board := "team"
var page := 0
var total := 0

func _ready() -> void:
	NetSession.api.leaderboard_loaded.connect(_on_loaded)
	NetSession.api.leaderboard_failed.connect(_on_failed)
	_load()

func _exit_tree() -> void:
	if NetSession.api.leaderboard_loaded.is_connected(_on_loaded):
		NetSession.api.leaderboard_loaded.disconnect(_on_loaded)
	if NetSession.api.leaderboard_failed.is_connected(_on_failed):
		NetSession.api.leaderboard_failed.disconnect(_on_failed)

func _load() -> void:
	status_label.text = "正在读取…"
	NetSession.api.load_leaderboard(current_board, PAGE_SIZE, page * PAGE_SIZE)

func _on_loaded(board: String, entries: Array, entry_total: int) -> void:
	if board != current_board:
		return
	total = entry_total
	var lines: Array[String] = []
	if entries.is_empty():
		lines.append("这一页还没有成绩。")
		lines.append("")
		lines.append("联机对局结束后，服务端会对各客户端上报的成绩做多数投票，")
		lines.append("一致才写榜——所以至少要 2 人完成一局才会出现在这里。")
	for entry in entries:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var rank := int(entry.get("rank", 0))
		var nickname := String(entry.get("nickname", ""))
		if nickname == "":
			nickname = "（无名）"
		var value := int(entry.get("value", 0))
		var unit := "波" if current_board == "team" else "杀"
		lines.append("%2d.  %-24s  %d %s" % [rank, nickname, value, unit])
	entries_label.text = "\n".join(lines)
	var page_count := maxi(1, ceili(float(total) / float(PAGE_SIZE)))
	status_label.text = "%s · 第 %d/%d 页 · 共 %d 条 · 匿名身份（未认证）" % [
		"队伍波次榜" if current_board == "team" else "个人击杀榜",
		page + 1,
		page_count,
		total,
	]
	previous_button.disabled = page <= 0
	next_button.disabled = (page + 1) * PAGE_SIZE >= total

func _on_failed(_board: String, message: String) -> void:
	status_label.text = "读取失败：%s" % message
	entries_label.text = ""

func _on_team_board_button_pressed() -> void:
	if current_board == "team":
		return
	current_board = "team"
	page = 0
	_load()

func _on_kills_board_button_pressed() -> void:
	if current_board == "kills":
		return
	current_board = "kills"
	page = 0
	_load()

func _on_previous_page_button_pressed() -> void:
	if page <= 0:
		return
	page -= 1
	_load()

func _on_next_page_button_pressed() -> void:
	if (page + 1) * PAGE_SIZE >= total:
		return
	page += 1
	_load()

func _on_back_button_pressed() -> void:
	get_tree().change_scene_to_file(main_menu_scene_path)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_back_button_pressed()
		get_viewport().set_input_as_handled()
