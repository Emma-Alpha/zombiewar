extends RefCounted
class_name WeaponModTable

## 武器改装件的常量表。纯静态数据，属于模拟层。
##
## 【为什么全部是整数千分比】
## 改装效果要在四台机器上算出逐位相同的结果。浮点连乘的结合律在不同平台/不同
## 编译下并不保证一致，`pow()` 更是走平台 libm。所以所有缩放一律写成千分比整数
## （1000 = 不变），叠加靠整数乘除的循环，绝不写 `base * 1.1 ** level`。
##
## 【enum 只能末尾追加】
## Mod 的下标就是 mod_id，也就是 SimWorld.player_mod_level 这个展平字节数组的布局，
## 而那个数组逐 tick 进帧哈希。往中间插一项会让所有已存的层数整体错位——而且是
## **各端一致地错位**，帧哈希不会报警，只有玩家发现"我的穿透变成了弹丸"。
##
## 【负面代价是设计的一部分】
## HEAVY_CORE 与 HOLLOW_POINT 带明确代价。取舍是构筑深度的主要来源，
## 但它们的代价必须在地面标签上写出来（PickupDefinition.effect_text），
## 否则玩家只会觉得"我捡了个东西然后变菜了"。

enum Mod {
	DAMAGE,
	PIERCE,
	SPLIT,
	COMPENSATOR,
	LONG_BARREL,
	MATCHED,
	CHOKE,
	STABILIZER,
	HEAVY_CORE,
	HOLLOW_POINT,
}

## 手写常量而不是 Mod.size()：它同时是 player_mod_level 的步长，
## validate_weapon_mods.gd 会断言两者相等，漏改会被挡下。
const COUNT := 10

const MOD_IDS: Array[StringName] = [
	&"damage",
	&"pierce",
	&"split",
	&"compensator",
	&"long_barrel",
	&"matched",
	&"choke",
	&"stabilizer",
	&"heavy_core",
	&"hollow_point",
]

const MOD_LABELS_CN: Array[String] = [
	"伤害",
	"穿透",
	"弹丸",
	"控枪",
	"枪管",
	"精配",
	"收束",
	"握把",
	"弹芯",
	"空尖",
]

## 每种改装件的叠加上限。层数存在 PackedByteArray 里，因此恒不超过 255。
const MAX_STACKS: Array[int] = [6, 3, 3, 3, 2, 3, 2, 3, 2, 2]

## ---- 乘性效果：千分比，1000 = 不变，逐层相乘 ----
const DAMAGE_PERMILLE: Array[int] = [
	1080, 1000, 720, 1000, 1000, 1100, 1000, 1000, 1250, 1350
]
const RANGE_PERMILLE: Array[int] = [
	1000, 1000, 1000, 1000, 1400, 1000, 1000, 1000, 1000, 1000
]
const BASE_SPREAD_PERMILLE: Array[int] = [
	1000, 1000, 1000, 1000, 700, 600, 1000, 1000, 1000, 1000
]
const MAX_SPREAD_PERMILLE: Array[int] = [
	1000, 1000, 1000, 1000, 1000, 1000, 550, 1000, 1000, 1000
]
const INCREASE_PERMILLE: Array[int] = [
	1000, 1000, 1000, 600, 1000, 1000, 1000, 1000, 1000, 1000
]
const RECOVERY_PERMILLE: Array[int] = [
	1000, 1000, 1000, 1000, 1000, 1000, 1000, 1800, 1000, 1000
]

## ---- 加性效果：逐层相加 ----
## 基础散布的加量，单位是**毫度**（1000 = 1 度）。乘性缩放先算，再加这个。
const BASE_SPREAD_ADD_MDEG: Array[int] = [
	0, 0, 0, 0, 150, 0, 0, 0, 600, 0
]
const PELLET_ADD: Array[int] = [
	0, 0, 1, 0, 0, 0, 0, 0, 0, 0
]
## 可以为负：空尖弹用伤害换掉穿透能力。
const PENETRATION_ADD: Array[int] = [
	0, 1, 0, 0, 0, 0, 0, 0, 0, -1
]

## PIERCE 第一层把穿透衰减系数抬到这个下限（千分比），此后每层再加一次。
## 单独处理是因为多数武器的基础系数是 0（穿透关闭），纯乘法永远抬不起来。
const PENETRATION_COEF_FLOOR := 650
const PENETRATION_COEF_ADD := 75


static func mod_index_from_id(id: StringName) -> int:
	for index in range(COUNT):
		if MOD_IDS[index] == id:
			return index
	return -1
