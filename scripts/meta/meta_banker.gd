class_name MetaBanker
extends RefCounted

## 判定一局结束时该把多少材料存入跨局银行。
## 规则：仅单人局累加；本地/联机不累加（避免刷币 + 不碰网络同步）。
static func compute_banked(mode: int, online_mode: bool, material: int) -> int:
	# GameSessionState.Mode.SINGLE == 0（见 game_session.gd Mode 枚举）
	const MODE_SINGLE := 0
	if online_mode:
		return 0
	if mode != MODE_SINGLE:
		return 0
	return maxi(0, material)
