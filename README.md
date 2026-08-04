# Zombie War

Godot 4.7.1 2.5D zombie-game control prototype.

## Run

Open `project.godot` in Godot 4.7.1 and run the configured main scene, or use:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

## Controls

- `W/A/S/D`: camera-relative movement and facing
- Release movement keys: retain the last facing direction
- `Space`: grounded jump
- Hold `J`: fire the rifle along the current facing direction
- Change `W/A/S/D` while firing: immediately redirect movement, facing, and the next shot together

- WASD始终同时改变移动、角色朝向和射击方向；按住J时改变WASD会立即朝新方向开火。
- 松开WASD后保留最后一个非零方向，原地按住J会沿该方向继续射击。
- 步枪使用5度、18米内的轻微胸口辅助命中，但不会穿过车辆、集装箱或墙体。
- 命中产生短时空中血花；地面血迹在本局内永久保留，达到192个后复用最旧血迹。

Mouse input is not used by the demo.

### Mobile H5 controls

- Touchscreen devices automatically show a left virtual joystick, a hold-to-fire button, and a jump button.
- The joystick reuses the same movement/facing rules as WASD; releasing it retains the last facing direction.
- Movement, jump, and hold-to-fire support simultaneous multi-touch input.
- Non-touch desktop browsers keep the keyboard control panel and hide the mobile overlay.

## Demo scope

The demo contains one orthographic 2.5D arena, a controllable player, static collision props, and four active damageable zombies. Each zombie has 50 health; the rifle deals 25 base damage at 6 shots per second. The player starts with 100 health.

Zombies wander randomly at low speed around their own spawn points by default. When the player enters the 7-unit perception range, they approach slowly at the speed supplied by the selected difficulty profile. They only stop and begin a punch after the player enters the fixed 1.45-unit attack range; the hit follows a 0.50-second windup and each attack uses the fixed 1.40-second cooldown. Difficulty changes only the perception approach speed, never attack damage or frequency. Player damage updates the HUD, flashes the screen, interrupts normal animation briefly, and lethal damage disables movement and shooting before showing `PLAYER DOWN`.

Zombie targets use overlapping head, torso, side, and leg hitboxes so shots can connect across a forgiving silhouette instead of one narrow line. Hits apply collision-aware knockback through `CharacterBody3D`; head, torso, side, and leg impacts use different damage, horizontal impulse, lift, and visual torque. Every successful hit also spawns a short Kenney CC0 blood splat plus directional Godot droplets. Persistent ground blood is projected only onto the arena ground and reuses its oldest splat after 192 instances.

See `docs/assets/shooting-impact-assets.md` for the reviewed Quaternius, Kenney, and Poly Haven sources and license notes.

Navigation-mesh pathfinding and obstacle avoidance, spawn waves, experience, upgrades, loot, and persistent roguelite runs are intentionally reserved for the next milestone.

## Tests

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

## Export and mobile verification

```bash
mkdir -p build/web
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --export-release Web build/web/index.html
rsync -a build/web/ /opt/homebrew/var/www/zombiewar/
curl -k -I https://zombiewar.devlocal.com/
curl -k -I https://zombiewar.devlocal.com/index.wasm
```

The homepage and `index.wasm` responses must both include `Cache-Control: no-store, no-cache, must-revalidate, max-age=0`. The `index.wasm` response must also include `Content-Type: application/wasm`.

Open `https://zombiewar.devlocal.com` from a phone that resolves `*.devlocal.com` to this Mac. Use landscape orientation and verify joystick movement, jump, hold-to-fire, simultaneous touches, audio unlock after the first tap, and background/foreground recovery.
