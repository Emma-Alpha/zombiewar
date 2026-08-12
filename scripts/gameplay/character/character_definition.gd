extends Resource
class_name CharacterDefinition

## 一个可选角色。
##
## A 阶段四个角色共用同一个 GLTF，只靠 accent_color 区分——它落在脚下光环、
## 名牌描边和座位卡描边三处，而不是给模型整体染色：角色用的是单张 atlas，
## material_override 会把脸和武器一并染了。
##
## B 阶段的三围与被动直接往这个类上加字段，不另起资源。

@export var character_id: StringName
@export var display_name := "幸存者"
@export var accent_color := Color(1.0, 1.0, 1.0, 1.0)
