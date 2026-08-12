extends Resource
class_name ShopCatalog

## 波间商店物品目录。波间开始时从 entries 里确定性选 N 个（用 DeterministicRng 的
## SHOP 流，各端同种子算出同一份），不会重复选同一个条目。

@export var entries: Array[ShopOfferDefinition] = []

func count() -> int:
	return entries.size()

func entry_at(index: int) -> ShopOfferDefinition:
	if index < 0 or index >= entries.size():
		return null
	return entries[index]
