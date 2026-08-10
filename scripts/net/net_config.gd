extends RefCounted
class_name NetConfig

## 服务端地址的唯一解析点。
##
## 三层覆盖，从低到高：
##   1. DEFAULT_BASE_URL —— 打包进版本的生产地址。
##   2. 项目设置 `zombiewar/net/server_base_url` —— 让导出预设按渠道改地址，
##      不必改代码。
##   3. `user://net.cfg` 的 `[net] base_url` —— 本机覆盖，局域网联调用，
##      永远不进版本库。
##
## Web 导出下还有第 4 层：URL 查询参数 `?server=`。浏览器里没有 `user://`
## 可编辑，而联调时最需要的恰恰是「同一份构建指向另一台服务器」。
const DEFAULT_BASE_URL := "https://zombiewar-server.workers.dev"
const SETTING_KEY := "zombiewar/net/server_base_url"
const OVERRIDE_PATH := "user://net.cfg"

static func base_url() -> String:
	var resolved := DEFAULT_BASE_URL
	if ProjectSettings.has_setting(SETTING_KEY):
		var configured := String(ProjectSettings.get_setting(SETTING_KEY, ""))
		if configured.strip_edges() != "":
			resolved = configured
	var file_override := _read_override()
	if file_override != "":
		resolved = file_override
	var query_override := _read_query_override()
	if query_override != "":
		resolved = query_override
	return resolved.strip_edges().rstrip("/")

## HTTP(S) -> WS(S)。分开写两个函数而不是让调用方自己拼，是因为
## 「忘了把 https 换成 wss」在浏览器里表现为一条被混合内容策略拦掉的连接，
## 报错信息与「服务器没起来」完全一样。
static func websocket_url(room_code: String) -> String:
	var http := base_url()
	var scheme := "wss://" if http.begins_with("https://") else "ws://"
	var authority := http.trim_prefix("https://").trim_prefix("http://")
	return "%s%s/ws/rooms/%s" % [scheme, authority, room_code.to_upper()]

static func api_url(path: String) -> String:
	return "%s%s" % [base_url(), path if path.begins_with("/") else "/" + path]

static func _read_override() -> String:
	if not FileAccess.file_exists(OVERRIDE_PATH):
		return ""
	var config := ConfigFile.new()
	if config.load(OVERRIDE_PATH) != OK:
		return ""
	return String(config.get_value("net", "base_url", "")).strip_edges()

static func _read_query_override() -> String:
	if not OS.has_feature("web"):
		return ""
	var href = JavaScriptBridge.eval("window.location.search", true)
	if typeof(href) != TYPE_STRING:
		return ""
	var query := String(href).trim_prefix("?")
	for pair in query.split("&", false):
		var parts := String(pair).split("=", true, 1)
		if parts.size() == 2 and parts[0] == "server":
			return String(parts[1]).uri_decode().strip_edges()
	return ""

## 把本机覆盖写回 user://net.cfg。联机大厅的「服务器」输入框用它，
## 免得玩家为了换一台服务器去翻文件系统。
static func save_override(url: String) -> void:
	var config := ConfigFile.new()
	config.load(OVERRIDE_PATH)
	config.set_value("net", "base_url", url.strip_edges().rstrip("/"))
	config.save(OVERRIDE_PATH)
