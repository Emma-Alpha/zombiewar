extends RefCounted
class_name SimHasher

## 对世界状态计算 64 位 FNV-1a 哈希，直接消费浮点的 IEEE 位模式，不做量化：
## 帧同步要求的是逐位一致而非近似一致。
## S0 阶段用于自测；S3 阶段用于周期性不同步检测。
const OFFSET_BASIS_HIGH := 0xCBF29CE4
const OFFSET_BASIS_LOW := 0x84222325
const UINT32_MASK := 0xFFFFFFFF
const PRIME_LOW_LIMB := 0x01B3
const PRIME_HIGH_SHIFT := 8

var hash_low := OFFSET_BASIS_LOW
var hash_high := OFFSET_BASIS_HIGH

func reset() -> void:
	hash_low = OFFSET_BASIS_LOW
	hash_high = OFFSET_BASIS_HIGH

func mix_byte(value: int) -> void:
	hash_low ^= value & 0xFF
	_multiply_prime()

func mix_bytes(bytes: PackedByteArray) -> void:
	for byte_value in bytes:
		hash_low ^= byte_value
		_multiply_prime()

func mix_uint32(value: int) -> void:
	var masked := value & UINT32_MASK
	hash_low ^= masked & 0xFF
	_multiply_prime()
	hash_low ^= (masked >> 8) & 0xFF
	_multiply_prime()
	hash_low ^= (masked >> 16) & 0xFF
	_multiply_prime()
	hash_low ^= (masked >> 24) & 0xFF
	_multiply_prime()

func mix_int64(value: int) -> void:
	mix_uint32(value & UINT32_MASK)
	mix_uint32((value >> 32) & UINT32_MASK)

func get_hash_low() -> int:
	return hash_low

func get_hash_high() -> int:
	return hash_high

func get_hash_hex() -> String:
	return "%08x%08x" % [hash_high, hash_low]

## 纳入哈希的字段：僵尸的实体 id、位置、高度、朝向、血量、状态、目标槽位；
## 油桶的实体 id、位置、状态、命中计数、引信剩余 tick；玩家量化快照与散布；
## 各 RNG 流的 state、当前 tick。Packed 数组的 to_byte_array() 直接给出
## 小端 IEEE 位模式，无需逐元素拆解。
##
## 不哈希阻挡网格（约 1.9 KB/tick，会让 3000 tick 的回归多跑两成）：
## 模拟层内部唯一会改动阻挡格的就是油桶的注册与引爆，而油桶的
## state / hit_count / fuse_ticks 已经逐 tick 进了哈希，网格分叉必然先在这里暴露。
## 表现层驱动的放置与拾取箱增删属于 S3 的输入同步范畴，不由本层的哈希覆盖。
static func hash_world(world: SimWorld) -> String:
	var hasher := new()
	hasher.mix_uint32(world.get_tick())
	hasher.mix_uint32(world.get_zombie_count())
	hasher.mix_uint32(world.get_next_entity_id())
	hasher.mix_bytes(world.zombie_id.to_byte_array())
	hasher.mix_bytes(world.zombie_position.to_byte_array())
	hasher.mix_bytes(world.zombie_height.to_byte_array())
	hasher.mix_bytes(world.zombie_facing.to_byte_array())
	hasher.mix_bytes(world.zombie_health.to_byte_array())
	hasher.mix_bytes(world.zombie_state)
	hasher.mix_bytes(world.zombie_target_slot)
	hasher.mix_uint32(world.get_barrel_count())
	hasher.mix_bytes(world.barrel_id.to_byte_array())
	hasher.mix_bytes(world.barrel_position.to_byte_array())
	hasher.mix_bytes(world.barrel_state)
	hasher.mix_bytes(world.barrel_hit_count.to_byte_array())
	hasher.mix_bytes(world.barrel_fuse_ticks.to_byte_array())
	# 补给箱进哈希：它的领取会清掉一块阻挡格，从而改写流场。领取时刻在各端
	# 错开一个 tick，僵尸就从此走不同的路——而这正是最难靠肉眼发现的那种分叉。
	hasher.mix_uint32(world.get_chest_count())
	hasher.mix_bytes(world.chest_id.to_byte_array())
	hasher.mix_bytes(world.chest_position.to_byte_array())
	hasher.mix_bytes(world.chest_state)
	hasher.mix_bytes(world.player_position_quantized.to_byte_array())
	hasher.mix_bytes(world.player_alive)
	hasher.mix_bytes(world.player_present)
	hasher.mix_bytes(world.player_spread_degrees.to_byte_array())
	for state_word in world.get_rng().get_state_words():
		hasher.mix_int64(state_word)
	return hasher.get_hash_hex()

## hash = hash * 0x100000001B3 (mod 2^64)
func _multiply_prime() -> void:
	var limb_0 := hash_low & 0xFFFF
	var limb_1 := (hash_low >> 16) & 0xFFFF
	var limb_2 := hash_high & 0xFFFF
	var limb_3 := (hash_high >> 16) & 0xFFFF
	var column_0 := limb_0 * PRIME_LOW_LIMB
	var column_1 := limb_1 * PRIME_LOW_LIMB + (column_0 >> 16)
	var column_2 := (
		limb_2 * PRIME_LOW_LIMB + (limb_0 << PRIME_HIGH_SHIFT) + (column_1 >> 16)
	)
	var column_3 := (
		limb_3 * PRIME_LOW_LIMB + (limb_1 << PRIME_HIGH_SHIFT) + (column_2 >> 16)
	)
	hash_low = (column_0 & 0xFFFF) | ((column_1 & 0xFFFF) << 16)
	hash_high = (column_2 & 0xFFFF) | ((column_3 & 0xFFFF) << 16)
