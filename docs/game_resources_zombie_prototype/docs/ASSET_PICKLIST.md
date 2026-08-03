# 首版挑选清单

## 必用

| 游戏对象 | 文件 | 备注 |
| --- | --- | --- |
| 玩家 | `assets/characters/Characters_Lis_SingleWeapon.gltf` | 已持单枪，适合先验证移动射击 |
| 普通僵尸 | `assets/enemies/Zombie_Basic.gltf` | 用于游荡、追击、攻击、死亡 |
| 重装僵尸 | `assets/enemies/Zombie_Chubby.gltf` | 速度慢、伤害和击退更高 |
| 视觉步枪 | `assets/weapons/Rifle.gltf` | 第一期可不绑定，先独立摆出来检查尺寸 |
| 废车 | `assets/vehicles/Vehicle_Pickup.gltf` | 固定场景的主要绕行障碍 |
| 可爆油桶 | `assets/environment/Barrel.gltf` | 子弹命中后播放爆炸效果并范围伤害 |
| 事件补给箱 | `assets/environment/Chest.gltf` | 打开后触发尸潮或掉落补给 |
| 大型阻挡物 | `assets/environment/Container_Red.gltf` | 形成路线选择，不要封死地图 |

## 从 Kenney 包中补齐

| 需要 | 搜索文件名 | 用法 |
| --- | --- | --- |
| 木箱 | `box`、`chest` | 可破坏物、弹药箱 |
| 围栏／铁皮 | `fence`、`metal-panel`、`structure-metal` | 限制路线，保留缺口 |
| 地面细节 | `patch-grass`、`rock`、`floor` | 打散空地，别影响移动 |
| UI | `assets/ui/PNG` | 血条、技能按钮、拾取提示 |
| 音效 | `assets/sfx` | 先选 1 个点击、1 个受击、1 个爆炸即可 |

## 这批先不做

- 不做多角色选择、Boss、联机皮肤、完整室内建筑。
- 不做高精度碰撞、布料、布偶和材质替换。
- 不把整套资源都摆进同一张图。场景里控制在 6～8 类模型，画面才不会乱。

