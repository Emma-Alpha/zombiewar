extends Node

## 联机会话的持有者，注册为 autoload。
##
## 它存在的唯一理由是 `change_scene_to_file()`：房间连接必须跨越
## 大厅场景 -> 竞技场场景的切换活下来。把 RoomClient 挂在大厅场景上，
## 场景一换连接就断，玩家会在进本的瞬间掉线——而这个 bug 只在联机时出现，
## 单机与本地多人下永远复现不了。

const ApiClientScript = preload("res://scripts/net/api_client.gd")
const IdentityStoreScript = preload("res://scripts/net/identity_store.gd")
const RoomClientScript = preload("res://scripts/net/room_client.gd")

signal identity_ready(nickname: String)
signal identity_failed(message: String)

var identity = IdentityStoreScript.new()
var api: ApiClient
var room: RoomClient

## 由大厅在开局时填好，竞技场读取。
var match_seed := 0
var local_slot := -1
var slot_nicknames: Dictionary = {}
var last_error := ""

func _ready() -> void:
	identity.load_or_create()
	api = ApiClientScript.new()
	api.name = "ApiClient"
	add_child(api)
	room = RoomClientScript.new()
	room.name = "RoomClient"
	add_child(room)
	api.authenticated.connect(_on_authenticated)
	api.auth_failed.connect(_on_auth_failed)

## 匿名身份是每次进联机入口就刷新一次的：令牌只活在内存里，
## 而玩家可能已经在别处改过昵称。
func ensure_identity(nickname: String = "") -> void:
	if nickname != "":
		identity.set_nickname(nickname)
	api.authenticate(identity.device_id, identity.nickname)

func has_token() -> bool:
	return identity.token != ""

func is_online_match() -> bool:
	return local_slot >= 0 and room != null and room.is_connected_to_room()

## 延迟显示的变色阈值（毫秒），大厅与对局 HUD 共用这一份，保证两处颜色一致。
## 档位照王者荣耀的手感：绿通畅、黄可玩、红卡顿。
const LATENCY_GOOD_MS := 20    ## < 此值：绿
const LATENCY_FAIR_MS := 150   ## < 此值：黄；>= 此值：红
const LATENCY_MAX_DISPLAY_MS := 460  ## 显示值封顶，再高也只显示这个数

## 当前联机往返时延（毫秒）。-1 表示未知或未联机。供 HUD 做王者荣耀式延迟显示。
func latency_ms() -> int:
	if room == null:
		return -1
	return room.last_rtt_ms()

## 延迟显示用的毫秒数：未知返回 -1，超过封顶值按封顶显示（实际卡顿不会因此看不见）。
func latency_display_ms() -> int:
	var rtt := latency_ms()
	if rtt < 0:
		return -1
	return mini(rtt, LATENCY_MAX_DISPLAY_MS)

## 延迟对应的显示颜色，按 LATENCY_*_MS 分档。
func latency_color(rtt_ms: int) -> Color:
	if rtt_ms < 0:
		return Color(0.6, 0.6, 0.6)
	if rtt_ms < LATENCY_GOOD_MS:
		return Color(0.42, 0.9, 0.48)
	if rtt_ms < LATENCY_FAIR_MS:
		return Color(0.98, 0.8, 0.2)
	return Color(0.96, 0.34, 0.22)

func begin_match(seed_value: int, slots: Array) -> void:
	match_seed = seed_value
	local_slot = room.slot
	slot_nicknames.clear()
	for entry in slots:
		if typeof(entry) == TYPE_DICTIONARY:
			slot_nicknames[int(entry.get("slot", -1))] = String(entry.get("nickname", ""))

func nickname_for_slot(slot: int) -> String:
	return String(slot_nicknames.get(slot, "玩家 %d" % (slot + 1)))

func clear_match() -> void:
	match_seed = 0
	local_slot = -1
	slot_nicknames.clear()

func leave_room() -> void:
	clear_match()
	if room != null:
		room.leave()

func _on_authenticated(player_id: String, token: String, nickname: String) -> void:
	identity.player_id = player_id
	identity.token = token
	identity.nickname = nickname
	identity.save()
	last_error = ""
	identity_ready.emit(nickname)

func _on_auth_failed(code: String, message: String) -> void:
	last_error = "%s: %s" % [code, message]
	identity_failed.emit(message)
