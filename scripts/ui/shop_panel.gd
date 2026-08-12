extends Control
class_name ShopPanel

## 波间商店面板：显示金钱 + 商品列表 + 购买按钮。
##
## arena 在 intermission_started 时 set_offers() + set_material() + show()，
## wave_started 时 hide()。购买按钮发 buy_requested(offer_index)，arena 处理
## 发命令/表现层 grant。金钱不足的按钮禁用（连 material_changed 刷新）。

signal buy_requested(offer_index: int)

@onready var material_label: Label = $Margin/VBox/MaterialLabel
@onready var offers_container: VBoxContainer = $Margin/VBox/OffersContainer

var _offers: Array[ShopOfferDefinition] = []
var _material := 0

func set_material_count(amount: int) -> void:
	_material = amount
	if material_label != null:
		material_label.text = "材料：%d" % amount
	_refresh_buttons()

func set_offers(offers: Array) -> void:
	_offers = offers
	if offers_container == null:
		return
	# 清掉旧的按钮
	for child in offers_container.get_children():
		child.queue_free()
	for index in range(offers.size()):
		var offer := offers[index] as ShopOfferDefinition
		if offer == null:
			continue
		var button := Button.new()
		button.text = "%s · %d材料" % [offer.display_name, offer.price]
		button.pressed.connect(func(): buy_requested.emit(index))
		offers_container.add_child(button)
	_refresh_buttons()

## 按钮在金钱足够时才可点；不足的置灰。
func _refresh_buttons() -> void:
	if offers_container == null:
		return
	var children := offers_container.get_children()
	for index in range(_offers.size()):
		if index >= children.size():
			break
		var button := children[index] as Button
		if button == null:
			continue
		var offer := _offers[index]
		button.disabled = offer.price > _material
