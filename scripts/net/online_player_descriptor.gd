extends RefCounted
class_name OnlinePlayerDescriptor

## 联机座位的描述符，与 `LocalPlayerDescriptor` 同形：`LocalPlayerSpawner`
## 靠鸭子类型消费两者，于是玩家生成与战斗逻辑不因联机而分叉。
##
## 本机座位刻意返回 null 输入源：本机玩家用的是竞技场自己那一个
## `SinglePlayerInputSource` 实例（触屏摇杆已经接在它上面），
## 由 spawner 代入。新建一个只会让手机上的摇杆连不上任何人。

const NetworkInputSourceScript = preload("res://scripts/net/network_input_source.gd")

var player_index := 0
var is_local := false
var nickname := ""
## 该座位选定的角色。来自服务端 start 消息里的座位表，不是本机记忆——
## 开局瞬间座位会被压实，本机记住的编号可能已经指向别人。
var character_id: StringName = &""
var online := true

func source_key() -> StringName:
	return &"local_online" if is_local else StringName("network_%d" % player_index)

func create_input_source():
	return null if is_local else NetworkInputSourceScript.new()
