# Zombie War Start Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Initialize the Zombie War Godot project with a polished, keyboard- and mouse-accessible main menu that offers Start Game and Quit.

**Architecture:** Keep the menu self-contained in a `Control` scene with one GDScript controller. The controller owns focus, button effects, and actions so gameplay scenes can later be added without changing the menu structure. Use selected UI assets and one short UI click sound from the supplied CC0 resource bundle, while keeping the first screen lightweight and 2D.

**Tech Stack:** Godot 4.7, GDScript, Control UI, supplied CC0 Kenney UI and sound assets.

## Global Constraints

- Preserve `docs/game_resources_zombie_prototype/` as the original resource source; copy only the assets actually used into `res://assets/`.
- Use the existing Godot 4.7 project and GL Compatibility renderer configuration.
- Provide exactly two primary menu actions: `START GAME` and `QUIT`.
- Support mouse activation plus keyboard focus and activation.
- The Start action must provide a visible prototype confirmation until a playable scene exists; Quit must call `get_tree().quit()`.
- Use only supplied CC0 assets or original UI styling; source credits remain in the supplied documentation.

---

## File Structure

- Modify: `project.godot` — register the main menu scene as the run target and define display defaults.
- Create: `scenes/MainMenu.tscn` — responsive menu scene with title, subtitle, action buttons, status text, and audio player.
- Create: `scripts/main_menu.gd` — handles default focus, button hover states, start feedback, and application exit.
- Copy: `assets/ui/PNG/*` — only the selected UI texture(s), if they improve button styling after visual inspection.
- Copy: `assets/sfx/interface/Audio/*` — one selected UI click `.ogg` file if present; otherwise use the supplied impact audio only when it reads cleanly as a click.

### Task 1: Establish the runnable main-menu scene

**Files:**
- Modify: `project.godot`
- Create: `scenes/MainMenu.tscn`

**Interfaces:**
- Consumes: `res://project.godot` and Godot 4.7 Control node types.
- Produces: `res://scenes/MainMenu.tscn`, the configured application main scene.

- [ ] **Step 1: Create a structural smoke-test checklist**

Verify these scene elements exist after opening the scene in Godot:

```text
MainMenu (Control)
├── Background (ColorRect)
├── Content (VBoxContainer)
│   ├── Title (Label)
│   ├── Subtitle (Label)
│   ├── StartButton (Button)
│   ├── QuitButton (Button)
│   └── StatusLabel (Label)
└── ClickAudio (AudioStreamPlayer)
```

- [ ] **Step 2: Run the scene before implementation to verify no run target exists**

Run: `godot --path . --editor project.godot`

Expected: the existing project opens but has no configured main scene to run.

- [ ] **Step 3: Create the responsive Control hierarchy and project run target**

Create `scenes/MainMenu.tscn` using the hierarchy above. Anchor `Background` to the full viewport, center `Content`, set its width to 440 pixels, and give each button a minimum height of 64 pixels. In `project.godot`, set:

```ini
[application]
run/main_scene="res://scenes/MainMenu.tscn"
```

Use dark charcoal for the background, a red accent for the title and focus outline, uppercase button labels, and the game title `ZOMBIE WAR`.

- [ ] **Step 4: Run the scene to verify layout**

Run: `godot --path . --editor project.godot`

Expected: pressing Run launches the main menu, it remains centered when the window is resized, and both action buttons are visible.

- [ ] **Step 5: Commit the runnable scene scaffold**

```bash
git add project.godot scenes/MainMenu.tscn
git commit -m "feat: add zombie war main menu scene"
```

### Task 2: Add menu behavior and accessible focus handling

**Files:**
- Modify: `scenes/MainMenu.tscn`
- Create: `scripts/main_menu.gd`

**Interfaces:**
- Consumes: nodes named `StartButton`, `QuitButton`, `StatusLabel`, and `ClickAudio` in `res://scenes/MainMenu.tscn`.
- Produces: `MainMenu` behavior through `res://scripts/main_menu.gd`.

- [ ] **Step 1: Write behavior acceptance checks**

Use this manual behavior table as the test specification:

| Input | Expected result |
| --- | --- |
| Scene opens | `StartButton` has keyboard focus |
| Click or activate `START GAME` | Status reads `PROTOTYPE READY — GAMEPLAY COMING NEXT` |
| Click or activate `QUIT` | App closes cleanly |
| Press Tab | Focus moves between Start and Quit buttons |
| Hover either button | Its visual state changes without moving layout |

- [ ] **Step 2: Run the menu before scripting to verify actions are inert**

Run: `godot --path . --editor project.godot`

Expected: both buttons render but clicking them produces no status message and does not exit.

- [ ] **Step 3: Implement the menu controller**

Create `scripts/main_menu.gd` and attach it to `MainMenu`. It must expose these functions:

```gdscript
func _ready() -> void:
    start_button.grab_focus()

func _on_start_button_pressed() -> void:
    status_label.text = "PROTOTYPE READY — GAMEPLAY COMING NEXT"

func _on_quit_button_pressed() -> void:
    get_tree().quit()
```

Connect the `pressed` signals to the named handlers. Add hover and focus style overrides in the scene theme settings rather than changing node positions in code.

- [ ] **Step 4: Run the behavior acceptance checks**

Run: `godot --path . --editor project.godot`

Expected: every row in the behavior table passes, including a visible start confirmation and a clean app exit.

- [ ] **Step 5: Commit menu interactions**

```bash
git add scenes/MainMenu.tscn scripts/main_menu.gd
git commit -m "feat: implement main menu actions"
```

### Task 3: Apply supplied-resource polish and verify a distributable prototype entry screen

**Files:**
- Modify: `scenes/MainMenu.tscn`
- Copy: `assets/ui/PNG/<selected-file>.png`
- Copy: `assets/sfx/interface/Audio/<selected-file>.ogg`

**Interfaces:**
- Consumes: the supplied resource package at `docs/game_resources_zombie_prototype/`.
- Produces: a menu that uses only a minimal, verified subset of supplied CC0 assets and remains usable with absent optional sound.

- [ ] **Step 1: Inspect candidate UI and interface-sound files**

Run:

```bash
find docs/game_resources_zombie_prototype/assets/ui/PNG -type f | head -40
find docs/game_resources_zombie_prototype/assets/sfx -iname '*click*' -o -iname '*select*' | head -20
```

Expected: identify a legible button/panel texture and one short activation sound; do not copy a complete asset pack.

- [ ] **Step 2: Verify resource provenance before copying**

Confirm the assets remain covered by the resource pack licensing record:

```text
Kenney UI Pack — CC0 1.0
Kenney Interface Sounds — CC0 1.0
```

- [ ] **Step 3: Copy the selected assets and wire them to the menu**

Copy the exact inspected files under `res://assets/ui/` and `res://assets/sfx/`. Set the selected visual asset as a non-distorting panel or button decoration and assign the audio stream to `ClickAudio`. Play the click audio from both action handlers only when its stream is present.

- [ ] **Step 4: Run a final visual and interaction verification**

Run: `godot --path . --editor project.godot`

Expected: the 2D screen has legible high-contrast text at the project default window size, has no missing-resource warnings, both buttons work, and the menu remains usable with the audio device muted.

- [ ] **Step 5: Commit the resource polish**

```bash
git add scenes/MainMenu.tscn scripts/main_menu.gd assets/ui assets/sfx
git commit -m "style: polish main menu with prototype resources"
```

## Self-Review

1. **Spec coverage:** Project initialization is covered in Task 1; exactly two required menu actions are covered in Tasks 1 and 2; inspection and minimal use of the provided assets are covered in Task 3.
2. **Placeholder scan:** No unresolved implementation actions remain; the sole selected asset names are intentionally decided only after the required file inspection in Task 3.
3. **Type consistency:** The scene node names in Task 1 exactly match the GDScript dependencies and handler names in Task 2.

