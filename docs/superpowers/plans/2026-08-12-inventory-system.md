# 12 格背包系统 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 将地图拾取物接入确定性的 12 格玩家背包，并提供桌面/移动端背包面板和 image-2 生成的图标资源。

**Architecture:** 模拟层保存每个座位的 12 个背包槽位、可堆叠数量和改装等级，负责在固定 tick 中判断奖励是否可接收；槽位数组进入帧哈希。表现层的 InventoryComponent 镜像模拟层结果，适配现有 EquipmentController、RangedWeapon 和 PlaceableEquipment，HUD 通过信号刷新。背包 UI 使用 4×3 容器布局，图标由 image-2 生成的 atlas 提供。

**Tech Stack:** Godot 4.7.1、GDScript、PackedInt32Array、CanvasLayer/Control/GridContainer、Godot headless validation、内置 image_gen image-2 路径。

## Global Constraints

- 背包固定 12 格，UI 为 4×3；第一版不实现拖拽、丢弃、排序、保存读取或商店交互。
- 武器、弹药、油桶和改装件都进入背包；同类弹药堆叠；重复武器不新增槽位而补充对应弹药。
- 改装件拾取即在模拟层生效，同类改装件累加至 WeaponModTable.MAX_STACKS，背包只显示等级。
- 箱子领取、箱子刷新、背包接受/拒绝和改装生效只由模拟 tick 决定；表现层不能直接改变这些状态。
- 背包状态必须进入 SimHasher，跨线传输只使用稳定整数 profile，不把图标、字体或场景带入模拟层。
- 背包满、弹药满或改装件满级时，箱子保持 active、阻挡格不清除、掉落物不消失。
- 模拟代码继续使用 SimMath 规则；不引入 Godot Navigation 或 wall-clock gameplay timers。
- 新增中文 Control 必须显式覆盖 assets/fonts/NotoSansSC-UI.ttf，并运行 UI 字体覆盖校验。
- 保留工作区中用户已有的未提交修改，不重置、不覆盖无关文件、不提交 .godot/ 或 build/。

## File Map

### New files

- scripts/gameplay/inventory/inventory_slot.gd：轻量槽位数据结构。
- scripts/gameplay/inventory/inventory_component.gd：表现层/玩家侧背包镜像。
- scripts/gameplay/inventory/inventory_profile.gd：背包分类、图标区域和 UI 元数据 Resource。
- scenes/ui/InventoryPanel.tscn：背包面板和 12 个槽位容器。
- scripts/ui/inventory_panel.gd：面板开关、事件绑定和布局适配。
- scripts/ui/inventory_slot_view.gd：单槽位图标、数量、等级、选中状态绘制。
- resources/inventory/inventory_profiles.tres：稳定的 UI profile 目录。
- assets/ui/inventory/inventory_atlas.png：image-2 生成并处理的图标图集。
- assets/ui/inventory/inventory_atlas_source.png：生成源备份。
- tools/validation/validate_inventory.gd：背包规则、profile、资源引用和场景契约验证。
- tools/validation/support/fake_inventory_owner.gd：验证脚本使用的最小宿主。

### Modified files

- scripts/gameplay/pickup_definition.gd：添加稳定背包分类/profile 关联和显示元数据。
- scripts/gameplay/map/game_map_runtime.gd：按 resource path 排序注册背包 profile。
- scripts/sim/sim_world.gd：增加每座位 12 槽状态、奖励接收判断、弹药扣减和事件。
- scripts/sim/sim_hasher.gd：将背包槽位状态混入帧哈希。
- scripts/player/equipment_controller.gd：通过背包镜像同步武器拥有、弹药和油桶数量。
- scripts/player/player_controller.gd：持有背包组件，连接背包/装备变化并提供 UI 查询。
- scripts/combat/weapons/ranged_weapon.gd：射击消耗通过背包同步。
- scripts/player/placeable_equipment.gd：放置成功后通过背包扣除油桶数量。
- scripts/gameplay/gameplay_arena.gd：注册 profile、消费 inventory 事件、更新玩家镜像和 HUD。
- scenes/player/Player.tscn：实例化背包组件或绑定其脚本。
- scenes/gameplay/GameplayArena.tscn：添加 InventoryPanel、背包按钮和字体/主题资源。
- scenes/ui/MobileControls.tscn、scripts/ui/mobile_controls.gd：添加移动端背包按钮。
- project.godot：添加 toggle_inventory 输入动作。
- resources/pickups/*.tres、resources/mods/*.tres：绑定背包 profile 和图标区域。

---

## Task 1: 建立稳定的背包 profile 和槽位规则

**Files:**
- Create: scripts/gameplay/inventory/inventory_slot.gd
- Create: scripts/gameplay/inventory/inventory_profile.gd
- Create: resources/inventory/inventory_profiles.tres
- Modify: scripts/gameplay/pickup_definition.gd
- Modify: scripts/gameplay/map/game_map_runtime.gd
- Test: tools/validation/validate_inventory.gd
- Test support: tools/validation/support/fake_inventory_owner.gd

**Interfaces:**
- InventorySlot：profile_index:int、amount:int、is_empty() -> bool、clear() -> void。
- InventoryProfile：profile_id:StringName、category:Category、display_name:String、description:String、max_stack:int、weapon_id:StringName、mod_id:StringName、icon_region:Rect2。
- PickupDefinition.get_inventory_category() -> int、get_inventory_key() -> StringName、get_inventory_max_stack() -> int。
- GameMapRuntime.inventory_profiles() -> Array[InventoryProfile]、inventory_profile_index_for(reward_profile_index:int) -> int。

- [ ] Step 1: 先写验证契约，检查正好支持 12 格、每个 pickup/mod 有稳定 key、类别合法、弹药上限对应 RangedWeaponDefinition.max_ammo、改装上限对应 WeaponModTable.MAX_STACKS、图标区域非零且在 atlas 内、profile id 唯一、未知 key 不回退。
- [ ] Step 2: 运行验证确认失败：
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_inventory.gd
- [ ] Step 3: 实现有类型的 InventorySlot 和 InventoryProfile；槽位可变，profile 只读，不修改共享 .tres。
- [ ] Step 4: 扩展 PickupDefinition，显式保存 inventory category/key/max stack 及武器/改装关联。
- [ ] Step 5: 在 GameMapRuntime.load() 中按资源路径排序构建 profile 表，配置错误在提交地图前返回。
- [ ] Step 6: 为现有武器、弹药、油桶和十种改装件建立 profile，不在 SimWorld 数据中放纹理。
- [ ] Step 7: 运行 validator 和 headless editor import，两个命令都应退出 0。
- [ ] Step 8: 提交：git commit -m "feat: add inventory profiles and slot data"

## Task 2: 添加确定性的模拟层背包和拾取接受

**Files:**
- Modify: scripts/sim/sim_world.gd
- Modify: scripts/sim/sim_hasher.gd
- Modify: scripts/gameplay/map/game_map_runtime.gd
- Modify: scripts/gameplay/gameplay_arena.gd
- Test: tools/validation/validate_inventory.gd
- Test: tools/validation/validate_sim_chest_claim.gd

**Interfaces:**
- SimWorld.configure_inventory_profiles(profiles:Array[Dictionary]) -> void。
- SimWorld.get_inventory_slot_profile(slot:int, inventory_slot:int) -> int。
- SimWorld.get_inventory_slot_amount(slot:int, inventory_slot:int) -> int。
- SimWorld.can_accept_reward(slot:int, reward_profile_index:int, amount:int) -> bool。
- SimWorld.accept_reward(slot:int, reward_profile_index:int, amount:int) -> Dictionary。
- SimWorld.tick_inventory_events:Array[Dictionary]、tick_inventory_feedback:Array[Dictionary]。
- SimWorld.queue_ammo_spend(slot:int, weapon_profile_index:int) -> void。
- SimWorld.inventory_state_fingerprint() -> PackedInt32Array。

- [ ] Step 1: 扩展 validate_inventory.gd，覆盖首次获得、重复武器补弹、弹药堆叠、油桶堆叠、改装升级、背包满、弹药满和满级拒绝。
- [ ] Step 2: 运行验证确认缺少模拟 API。
- [ ] Step 3: 在 SimWorld 中增加每座位固定大小数组，reset 为 -1/0，大小为 MAX_PLAYER_SLOTS * 12。
- [ ] Step 4: 实现确定性接受：先找已有槽，再取最低空槽；重复武器合并到对应弹药；改装件调用 grant_weapon_mod 并同步等级槽。
- [ ] Step 5: 修改 _resolve_chest_claims()，先 accept_reward()，成功后才清阻挡和改变箱子状态；失败只产生 feedback，箱子保持 active。
- [ ] Step 6: 增加确定性的弹药消耗和油桶消耗事件，继续复用现有输入/模拟请求通道。
- [ ] Step 7: 将槽位数组、弹药消耗、油桶消耗和改装等级混入 SimHasher。
- [ ] Step 8: 让 accepted event 带 slot/profile/amount，feedback 带 slot/reward/reason；事件不得携带 UI 资源。
- [ ] Step 9: 运行 validate_inventory、validate_sim_chest_claim、validate_sim_determinism，全部应 PASS。
- [ ] Step 10: 提交：git commit -m "feat: make pickup inventory deterministic"

## Task 3: 把模拟层背包镜像到玩家装备

**Files:**
- Create: scripts/gameplay/inventory/inventory_component.gd
- Modify: scripts/player/player_controller.gd
- Modify: scripts/player/equipment_controller.gd
- Modify: scripts/combat/weapons/ranged_weapon.gd
- Modify: scripts/player/placeable_equipment.gd
- Modify: scripts/gameplay/gameplay_arena.gd
- Modify: scenes/player/Player.tscn
- Test: tools/validation/validate_inventory.gd

**Interfaces:**
- InventoryComponent.inventory_changed。
- InventoryComponent.slot_changed(slot_index:int, profile_index:int, amount:int)。
- InventoryComponent.apply_sim_snapshot(slot_profiles:PackedInt32Array, slot_amounts:PackedInt32Array) -> void。
- InventoryComponent.get_slot(slot_index:int) -> InventorySlot。
- InventoryComponent.find_slot(profile_index:int) -> int。
- InventoryComponent.get_weapon_ammo(weapon_id:StringName) -> int。
- InventoryComponent.get_oil_count() -> int。
- InventoryComponent.set_equipment_adapter(equipment:EquipmentController) -> void。
- EquipmentController.bind_inventory(inventory:InventoryComponent) -> void。
- PlayerController.get_inventory() -> InventoryComponent。
- PlayerController.apply_inventory_event(event:Dictionary) -> void。

- [ ] Step 1: 添加镜像验证：快照更新 12 槽、空槽清空、武器拥有跟随武器槽、弹药跟随背包、油桶没有第二份独立计数。
- [ ] Step 2: 运行验证确认镜像 API 尚不存在。
- [ ] Step 3: 实现 InventoryComponent 作为表现镜像；它只发信号和保存镜像，不能决定箱子是否接受。
- [ ] Step 4: 绑定 EquipmentController，保留现有武器实例和避让切换守卫，从快照同步 ownership/ammo/oil。
- [ ] Step 5: 射击和放置油桶通过已有请求路径扣除模拟层资源；表现节点可预测显示，但以返回帧事件校正。
- [ ] Step 6: 正常竞技场路径不再直接用 PickupDefinition.grant_to() 改变 gameplay；该方法只保留给兼容工具。
- [ ] Step 7: 当前武器、弹药、油桶和改装摘要继续刷新现有 HUD/头顶标签。
- [ ] Step 8: 运行 validate_inventory、validate_equipment_cycle、validate_weapon_assembly，全部应 PASS。
- [ ] Step 9: 提交：git commit -m "feat: mirror inventory into player equipment"

## Task 4: 用 image-2 生成并导入图标 atlas

**Files:**
- Create: assets/ui/inventory/inventory_atlas_source.png
- Create: assets/ui/inventory/inventory_atlas.png
- Create: assets/ui/inventory/inventory_icon_guide.md
- Modify: resources/inventory/inventory_profiles.tres
- Test: tools/validation/validate_inventory.gd

**Interfaces:**
- atlas 为 5 列 × 4 行、20 个等大单元格。
- 第 0 行：pistol、smg、shotgun、rifle、oil barrel。
- 第 1 行：pistol ammo、smg ammo、shotgun ammo、rifle ammo、reserved。
- 第 2 行：damage、pierce、split、compensator、long barrel。
- 第 3 行：matched、choke、stabilizer、heavy core、hollow point。
- InventoryProfile.icon_region 使用 atlas 单元格像素矩形；reserved 不被运行时引用。
- 无文字、logo、水印、字形符号、投影或色键残留。

- [ ] Step 1: 使用内置 image_gen image-2 路径生成固定 5×4 布局的低多边形末日军事图标。
- [ ] Step 2: 保留生成源到 workspace，不覆盖已有资源。
- [ ] Step 3: 逐格检查对象、风格、留白、文字和水印；错误格只做针对性重生成。
- [ ] Step 4: 使用 /Users/liangpingbo/.codex/skills/.system/imagegen/scripts/remove_chroma_key.py 移除纯色背景，验证 alpha 角点和边缘。
- [ ] Step 5: 将最终 atlas 保存到 assets/ui/inventory/inventory_atlas.png，运行时不引用 source。
- [ ] Step 6: 把 20 个单元格区域绑定到 profiles，reserved 不绑定。
- [ ] Step 7: 运行 headless import 和 validate_inventory。
- [ ] Step 8: 提交：git commit -m "feat: add inventory icon atlas"

## Task 5: 构建响应式背包面板和输入集成

**Files:**
- Create: scripts/ui/inventory_panel.gd
- Create: scripts/ui/inventory_slot_view.gd
- Create: scenes/ui/InventoryPanel.tscn
- Modify: scenes/gameplay/GameplayArena.tscn
- Modify: scripts/gameplay/gameplay_arena.gd
- Modify: project.godot
- Modify: scenes/ui/MobileControls.tscn
- Modify: scripts/ui/mobile_controls.gd
- Test: tools/validation/validate_inventory.gd
- Test: tools/validation/validate_ui_font_coverage.gd

**Interfaces:**
- InventoryPanel.bind_player(player:PlayerController) -> void。
- InventoryPanel.set_inventory(inventory:InventoryComponent) -> void。
- InventoryPanel.toggle_panel() -> void。
- InventoryPanel.close_panel() -> void。
- InventorySlotView.bind_profile(profile:InventoryProfile) -> void。
- InventorySlotView.set_slot_state(slot:InventorySlot, selected:bool) -> void。

- [ ] Step 1: 添加场景契约，检查 GridContainer.columns=4、12 个槽位、显式 CJK font、safe-area anchor 和无 per-frame inventory polling。
- [ ] Step 2: 运行契约验证确认场景尚不存在。
- [ ] Step 3: 实现 slot view：atlas region、数量/等级标签、空槽、当前装备高亮、悬停提示和键盘/手柄 focus。
- [ ] Step 4: 实现 panel：MarginContainer + PanelContainer + GridContainer，锚定右上安全区域，打开不暂停模拟。
- [ ] Step 5: 连接 inventory_changed 和 equipment changed 信号，禁止每帧读取库存。
- [ ] Step 6: 在 project.godot 添加 toggle_inventory，桌面使用 Tab，Escape 关闭。
- [ ] Step 7: 添加移动端背包按钮，复用已有 responsive action-button 缩放。
- [ ] Step 8: GameplayArena 只绑定本地玩家的背包，不能让多人共用面板。
- [ ] Step 9: 运行 inventory 和 UI font validation。
- [ ] Step 10: 提交：git commit -m "feat: add responsive inventory panel"

## Task 6: 端到端验证和设计参考检查

**Files:**
- Modify: tools/validation/validate_inventory.gd only when a discovered stable contract needs explicit coverage.
- No generated build output committed.

- [ ] Step 1: 运行 headless editor、validate_inventory、validate_sim_chest_claim、validate_sim_pickup_respawn、validate_online_frame_sync、validate_online_reconnect_resume 和 validate_ui_font_coverage，全部退出 0。
- [ ] Step 2: 运行 validate_weapon_assembly，确认武器锚点和当前装备显示没有回归。
- [ ] Step 3: 手动进入 Demo：开关背包、拾取四类资源、测试重复/堆叠/升级、填满 12 格、射击/放置/换武器、检查宽屏和移动端。
- [ ] Step 4: 联机由两个玩家同时接近同一箱子，比较箱子可见性、槽位、改装等级和 alive count。
- [ ] Step 5: 使用 zombie-crisis-reference 和 zombie-crisis-playtest 检查背包是否遮挡战斗关键 HUD、是否削弱 horde pressure。
- [ ] Step 6: git diff --check，并确认只提交源文件和最终资源，不提交 .godot、build、fontdata 或临时生成文件。
- [ ] Step 7: 汇报生成资源路径、验证结果和仍需人工执行的检查。

## Plan Self-Review

- Spec coverage：固定 12 格、四类拾取物、弹药堆叠、重复武器合并、改装升级、拒绝不消耗、tick/帧哈希、桌面/移动 UI、image-2 atlas、字体校验和人工验证均由 Task 1–6 覆盖。
- Placeholder scan：没有 TODO、TBD 或未定义的“稍后处理”步骤。
- Type consistency：profile 是稳定 map-runtime 整数；SimWorld API 使用 seat/profile/amount 整数；表现 API 使用 InventoryComponent/InventorySlot；UI 只绑定本地玩家。
- Worktree safety：计划保留现有无关脏文件，不使用 destructive git 操作。
