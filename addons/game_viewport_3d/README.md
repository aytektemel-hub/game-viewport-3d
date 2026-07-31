# Game Viewport 3D

Shows the running game **inside a pane of the 3D editor's split viewport** instead of the separate Game tab or a floating window — edit the scene in one pane while the game runs in the other.

![Toggling Game Window on a pane, playing, and stopping — the game lives inside the 3D editor](media/demo.gif)

## Features

- A **Game Window** toggle on every 3D viewport pane — tick one, press Play, and the game runs in that pane; Stop hands the pane back to 3D
- Activating the plugin in a 1-viewport layout creates the second viewport automatically, so you always keep an editing pane
- The Game view's own toolbar (sizing mode, scale, camera override, suspend, mute) docks directly above the game's pane, with added **×** (exit) and **fullscreen** buttons
- One continuous focus frame around the toolbar strip and pane shows which viewport the game owns
- The Game main-screen tab is hidden while active, so nothing yanks the editor out of the 3D workspace
- Games that capture the mouse (mouse-look) stay controllable in any pane
- Optional `fullscreen_on_play`: the game fills the editor during play and the layout is restored on stop

## Requirements

- **Godot 4.7 or newer** — the plugin declines to load on older versions
- A platform with game-window embedding (Windows, Linux/X11, macOS); developed and verified on 4.7.1/macOS
- Editor Settings: **Run → Window Placement → Game Embed Mode = Embed Game**, **Single Window Mode off**, **Multi Window enabled**

You don't need to set these by hand: on activation the plugin checks them and offers to apply the fixes in one click (restarting the editor once if the window-mode settings have to change). If embedding is unavailable anyway, the plugin stays inert and logs a warning — the normal Game tab keeps working.

## Install

**Asset Library (easiest):** open the **AssetLib** tab in the editor, search for *Game Viewport 3D*, **Download → Install** — the files land in `res://addons/game_viewport_3d/` automatically. Then enable it in **Project → Project Settings → Plugins**.

**From GitHub:** download the release zip, extract it, drag the **`addons`** folder into your project root (merge if one exists), then enable the plugin.

> **Updating:** disable the plugin before replacing its files — hot-reloading it while active can crash the editor.

## Usage

1. In the 3D workspace, tick **Game Window** beside a pane's **⋮ Perspective** menu.
2. Press **Play** — the game runs inside that pane while the other pane stays a fully editable 3D view.
3. Press **Stop** — the pane is a plain 3D view again.

Switch it off with the **×** on the game toolbar or by unticking **Game Window**. To move the game, untick one pane and tick another.

## Settings (Editor Settings → Game Viewport 3D)

| Setting | Default | Effect |
| --- | --- | --- |
| `switch_to_3d_on_play` | `true` | Hold the 3D workspace when Play is pressed. |
| `stretch_to_fit` | `true` | Make the game fill the pane on first relocation. |
| `show_game_toolbar` | `true` | Dock the Game toolbar above the game's pane. Off leaves it in the Game tab. |
| `keep_3d_on_game_focus` | `true` | Stop clicks into the game from switching workspaces. |
| `hide_game_tab` | `true` | Remove the Game tab from the main-screen selector while active. |
| `fullscreen_on_play` | `false` | Expand the game to the whole editor during play. |

## Limitations

- Built on undocumented editor internals, located by class name and driven only through generic Node/Control API. A future Godot release may move them — the plugin fails soft with a warning instead of breaking the editor.
- The embedded game composites **above** the editor: gizmos can't draw over it, and it hides when you leave the 3D workspace (exactly like the Game tab).
- macOS: games that *query* absolute cursor positions read wrong values while embedded (engine issue [#109597](https://github.com/godotengine/godot/issues/109597)); event-driven input is correct, and `fullscreen_on_play` mitigates it.

Deep documentation of how it all works: [docs/INTERNALS.md](https://github.com/aytektemel-hub/game-viewport-3d/blob/main/docs/INTERNALS.md).

## License

MIT — see `LICENSE`.
