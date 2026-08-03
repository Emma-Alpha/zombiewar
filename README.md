# Zombie War

Godot 4.7.1 2.5D zombie-game control prototype.

## Run

Open `project.godot` in Godot 4.7.1 and run the configured main scene, or use:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

## Controls

- `W/A/S/D`: camera-relative movement
- `Space`: grounded jump
- Mouse: aim on the arena floor
- Hold left mouse button: fire the rifle

## Demo scope

The demo contains one orthographic 2.5D arena, a controllable player, static collision props, and four damageable zombie practice targets. Each target has 50 health; the rifle deals 25 damage at 6 shots per second.

Enemy navigation, attacks, spawn waves, experience, upgrades, loot, and persistent roguelite runs are intentionally reserved for the next milestone.

## Tests

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```
