extends Label3D
class_name PlayerEquipmentLabel

## 玩家头顶的状态牌：第一行是当前装备，第二行是本局已获得的改装件。
##
## 两行分开存而不是每次拼整串，是因为它们由两条独立的事件驱动——换枪走
## equipment_changed，改装走模拟层的 chest_claimed——任何一条都不该覆盖掉另一条。

var equipment_line := ""
var mod_line := ""

func set_status(
	player_index: int,
	display_name: String,
	count_text: String
) -> void:
	equipment_line = "P%d · %s" % [player_index + 1, display_name]
	if not count_text.is_empty():
		equipment_line += ":%s" % count_text
	_refresh()

## 设置改装摘要。空串时第二行整行消失，而不是留一行空白——没捡到东西的玩家
## 头顶不该比别人多占一行高度。
func set_mod_summary(summary: String) -> void:
	mod_line = summary
	_refresh()

func _refresh() -> void:
	if mod_line.is_empty():
		text = equipment_line
		return
	text = "%s\n%s" % [equipment_line, mod_line]
