extends RefCounted
class_name IdentityStore

## 匿名设备身份的本地存档。
##
## `device_id` 是首次运行时生成的 UUIDv4，此后不再变化——它是玩家在排行榜上
## 的连续性来源，卸载重装就换人是可以接受的，换一次会话就换人不行。
##
## 它**不是**凭据。服务端只做形状校验，任何人都能声称任何 device_id。
## 详见 server/src/lib/sessions.ts 顶部那段说明。
const STORE_PATH := "user://identity.cfg"
const DEFAULT_NICKNAME := "幸存者"
const NICKNAME_MIN_LENGTH := 2
const NICKNAME_MAX_LENGTH := 12

var device_id := ""
var nickname := DEFAULT_NICKNAME
## 会话令牌只活在内存里：服务端那边它也会过期，落盘只会带来
## 「用一个早就失效的令牌反复失败」这一种新故障。
var token := ""
var player_id := ""

func load_or_create() -> void:
	var config := ConfigFile.new()
	var loaded := config.load(STORE_PATH) == OK
	device_id = String(config.get_value("identity", "device_id", "")) if loaded else ""
	nickname = String(config.get_value("identity", "nickname", DEFAULT_NICKNAME)) if loaded else DEFAULT_NICKNAME
	if not _is_uuid(device_id):
		device_id = generate_uuid_v4()
		save()

func save() -> void:
	var config := ConfigFile.new()
	config.load(STORE_PATH)
	config.set_value("identity", "device_id", device_id)
	config.set_value("identity", "nickname", nickname)
	config.save(STORE_PATH)

func set_nickname(value: String) -> void:
	nickname = sanitize_nickname(value)
	save()

## 与服务端 normalizeNickname 同规则：按码点计 2-12 个字符。
## GDScript 的 String.length() 本来就是码点数，所以「僵尸猎人」是 4 不是 8，
## 两端对同一个昵称给出同一个长度。
static func sanitize_nickname(value: String) -> String:
	var trimmed := value.strip_edges()
	if trimmed.length() < NICKNAME_MIN_LENGTH:
		return DEFAULT_NICKNAME
	if trimmed.length() > NICKNAME_MAX_LENGTH:
		trimmed = trimmed.substr(0, NICKNAME_MAX_LENGTH)
	return trimmed

static func generate_uuid_v4() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var bytes := PackedByteArray()
	bytes.resize(16)
	for index in range(16):
		bytes[index] = rng.randi() & 0xFF
	# 版本位与变体位。服务端只用正则校验形状，但发一个形状不合法的 UUID
	# 会被 400 挡下来，而那时错误信息会指向服务端，排查方向正好反了。
	bytes[6] = (bytes[6] & 0x0F) | 0x40
	bytes[8] = (bytes[8] & 0x3F) | 0x80
	var hex := ""
	for index in range(16):
		hex += "%02x" % bytes[index]
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8),
		hex.substr(8, 4),
		hex.substr(12, 4),
		hex.substr(16, 4),
		hex.substr(20, 12),
	]

static func _is_uuid(value: String) -> bool:
	if value.length() != 36:
		return false
	var regex := RegEx.new()
	regex.compile("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
	return regex.search(value) != null
