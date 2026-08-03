# 僵尸生存原型资源包

适用于首个 Godot 4 原型：固定停车场／加油站战场、零散游荡僵尸、事件触发尸潮、直线步枪射击和单主动技能。

## 已备资源

| 目录 | 用途 | 首版建议 |
| --- | --- | --- |
| `assets/characters` | 持枪主角，内置 20 个动作 | 用 `Characters_Lis_SingleWeapon.gltf` 作玩家 |
| `assets/enemies` | 两种带动作僵尸 | `Zombie_Basic` 普通尸，`Zombie_Chubby` 重装尸 |
| `assets/weapons` | 步枪模型 | 挂到主角右手骨骼；第一版只做视觉即可 |
| `assets/vehicles` | 废弃皮卡 | 放在场景中央，用于绕圈和阻挡尸群 |
| `assets/environment` | 油桶、补给箱、红色集装箱 | 油桶可爆，补给箱触发事件，集装箱形成绕行路线 |
| `assets/kenney_survival` | 木箱、围栏、铁皮、石块、地面和备用障碍 | 优先用 `Models/GLB format` 下的模型 |
| `assets/ui` | 按钮、血条、图标和控制条 | 原型阶段从 `PNG` 目录挑基础控件 |
| `assets/sfx` | UI 与命中反馈音效 | 拾取、按钮、受击、油桶爆炸的临时音效 |

## 导入 Godot

1. 解压后，将整个 `assets` 目录复制到 Godot 项目的 `res://assets/`。
2. `.gltf` 和 `.glb` 直接拖进场景；Godot 会在首次导入时生成可实例化场景。
3. 玩家和僵尸先使用根节点的 `AnimationPlayer` 查看动作列表。玩家文件含 **20** 段动画，两个僵尸各含 **16** 段动画。
4. 地图地面先用 Godot 的 `PlaneMesh`（60 x 60）即可，不要等道路模型齐了再验证玩法。
5. 模型只负责画面。碰撞体请在 Godot 内另建简化的 `CollisionShape3D`，不要直接拿模型网格做动态碰撞。

## 首张地图摆放建议

- 中央：一台 `Vehicle_Pickup`，外加两个 `Container_Red`，形成可绕圈路线。
- 西侧：油桶 `Barrel` + 补给箱 `Chest`，开箱时触发 45 秒尸潮。
- 北、东、南三侧：从 `kenney_survival` 选择围栏、木箱、铁皮，留出 2 个角色宽的通道。
- 角色出生点半径 8 米内保持空地；僵尸刷点放在地图外边缘，别直接刷在玩家视野旁。

## 用之前先看

- 这是原型美术：低多边形、轻写实偏卡通。先保证同屏轮廓和对比，后面再换正式美术。
- `assets/kenney_survival`、`assets/ui` 和 `assets/sfx` 各自原始的 `License.txt` 已保留在目录里。
- 详细来源和授权见 `licenses/SOURCES_AND_LICENSES.md`。

