extends Control
class_name ShopPanel

## 波间商店面板：Brotato 式卡片布局。
##
## 顶部材料数，中间 3-4 张卡片横排（图标+名称+效果+价格+选择按钮），
## 金钱不足的卡片置灰。arena 在 intermission_started 时 set_offers() + show()，
## wave_started 时 hide()。购买发 buy_requested(offer_index)。

signal buy_requested(offer_index: int)

@onready var material_label: Label = $Margin/VBox/MaterialLabel
@onready var offers_container: HBoxContainer = $Margin/VBox/OffersContainer

var _offers: Array[ShopOfferDefinition] = []
var _material := 0
var _cards: Array[Control] = []

func set_material_count(amount: int) -> void:
	_material = amount
	if material_label != null:
		material_label.text = "材料：%d" % amount
	_refresh_cards()

func set_offers(offers: Array) -> void:
	_offers = offers
	if offers_container == null:
		return
	for child in offers_container.get_children():
		child.queue_free()
	_cards.clear()
	for index in range(offers.size()):
		var offer := offers[index] as ShopOfferDefinition
		if offer == null:
			continue
		var card := _make_card(index, offer)
		offers_container.add_child(card)
		_cards.append(card)
	_refresh_cards()

## 做一张商品卡片：深色背景 + 图标 + 名称 + 效果 + 价格 + 选择按钮。
func _make_card(index: int, offer: ShopOfferDefinition) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(180, 240)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.09, 0.07, 0.95)
	style.border_color = Color(0.3, 0.35, 0.28, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	card.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	# 图标（按 offer_type 用对应图标，后续可换 image-2 生成的图标）
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(64, 64)
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = _icon_for_offer(offer)
	vbox.add_child(icon)

	# 名称
	var name_label := Label.new()
	name_label.text = offer.display_name
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", Color(0.95, 0.93, 0.89, 1.0))
	vbox.add_child(name_label)

	# 效果描述
	var effect_label := Label.new()
	effect_label.text = _effect_text(offer)
	effect_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	effect_label.add_theme_font_size_override("font_size", 14)
	effect_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.68, 1.0))
	vbox.add_child(effect_label)

	# 价格
	var price_label := Label.new()
	price_label.text = "%d 材料" % offer.price
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	price_label.add_theme_font_size_override("font_size", 16)
	price_label.add_theme_color_override("font_color", Color(0.95, 0.66, 0.0, 1.0))
	vbox.add_child(price_label)

	# 选择按钮
	var button := Button.new()
	button.text = "选择"
	button.pressed.connect(func(): buy_requested.emit(index))
	vbox.add_child(button)

	return card

## 按 offer_type 给卡片配图标（codex image-2 生成的）。
func _icon_for_offer(offer: ShopOfferDefinition) -> Texture2D:
	match offer.offer_type:
		ShopOfferDefinition.OfferType.WEAPON:
			return _load_icon("res://assets/ui/icons/shop_icon_weapon.png")
		ShopOfferDefinition.OfferType.PASSIVE:
			return _load_icon("res://assets/ui/icons/shop_icon_passive.png")
		ShopOfferDefinition.OfferType.STAT:
			return _load_icon("res://assets/ui/icons/shop_icon_stat.png")
		ShopOfferDefinition.OfferType.HEAL:
			return _load_icon("res://assets/ui/icons/shop_icon_heal.png")
		ShopOfferDefinition.OfferType.AMMO:
			return _load_icon("res://assets/ui/icons/shop_icon_ammo.png")
	return null

## 缓存加载图标（避免每次刷新都 load）。
static var _icon_cache: Dictionary = {}

func _load_icon(path: String) -> Texture2D:
	if _icon_cache.has(path):
		return _icon_cache[path]
	var tex := load(path) as Texture2D
	_icon_cache[path] = tex
	return tex

## 效果描述文案（按 offer_type）。
func _effect_text(offer: ShopOfferDefinition) -> String:
	match offer.offer_type:
		ShopOfferDefinition.OfferType.WEAPON:
			return "装备武器"
		ShopOfferDefinition.OfferType.PASSIVE:
			return "获得被动"
		ShopOfferDefinition.OfferType.STAT:
			return "属性提升"
		ShopOfferDefinition.OfferType.HEAL:
			return "恢复生命"
		ShopOfferDefinition.OfferType.AMMO:
			return "补充弹药"
	return ""

## 卡片在金钱足够时才可点；不足的置灰。
func _refresh_cards() -> void:
	for index in range(_cards.size()):
		if index >= _offers.size():
			break
		var card := _cards[index]
		var offer := _offers[index]
		var button := card.get_child(0).get_child(4) as Button
		if button != null:
			button.disabled = offer.price > _material
		card.modulate = Color(1, 1, 1, 1) if offer.price <= _material else Color(0.5, 0.5, 0.5, 1)
