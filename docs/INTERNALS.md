# Game Viewport 3D — engineering notes

This is the long-form documentation that shipped as the README up to v1.0.0:
the design rationale, the editor internals the plugin touches, and why each
mechanism works the way it does. It is kept for contributors and for future
debugging when a Godot release moves the internals around. The user-facing
README is now a short guide; sections here may drift as the plugin evolves.

---

# Game Viewport 3D

Shows the running game **inside a pane of the 3D editor's split viewport** instead of the separate **Game** tab or a floating window.

Keep your editor 3D view on top, watch the live game underneath, without leaving the 3D workspace.

![Toggling Game Window on a pane, playing, and stopping — the game lives inside the 3D editor](media/demo.gif)

```
┌─────────────────────────────┐
│                             │
│   3D editor viewport        │  ← Viewport 1
│                             │
├─────────────────────────────┤
│                             │
│   running game (embedded)   │  ← Viewport 2
│                             │
└─────────────────────────────┘
```

## Requirements

- **Godot 4.7 or newer** — the toolbar strip relies on 4.7's multi-child `SplitContainer`; on older editors the plugin declines to load with a warning instead of half-working
- A platform with window embedding support (Windows, Linux/X11, macOS)
- Developed and verified on **4.7.1.stable on macOS**; the code paths are platform-generic, but other platforms have not been hands-on tested — reports welcome
- **Editor Settings → Run → Window Placement → Game Embed Mode** must be `Embed Game`
- **Editor Settings → Interface → Editor → Display → Single Window Mode** must be **off**, and **Interface → Multi Window → Enable** **on** (changing these needs an editor restart)

That last one is easy to miss. Godot silently refuses to embed in single window mode — the game just opens as an ordinary floating window. The Game tab reports `Game embedding not available in single window mode`, and the game process is launched without the `--embedded` flag. If you are unsure whether embedding engaged, run the game and check:

```sh
ps -Ao command | grep -- --embedded
```

If embedding is unavailable the plugin stays inert and logs a warning to **Output** — the Game tab keeps working as normal.

## Install

**From the Asset Library (easiest):** open the **AssetLib** tab in the editor, search for *Game Viewport 3D*, then **Download → Install**. The files land in `res://addons/game_viewport_3d/` automatically — Godot creates the `addons` folder for you if the project doesn't have one.

**From GitHub:** download the release zip (or *Code → Download ZIP*), extract it, and drag the **`addons`** folder it contains into your project's root. If the project already has an `addons` folder, merge them. Either way the addon must end up at exactly:

```
res://addons/game_viewport_3d/
```

Then enable **Game Viewport 3D** in **Project → Project Settings → Plugins**.

The one thing that does not work is placing the inner `game_viewport_3d` folder anywhere else — Godot discovers editor plugins exclusively under `res://addons/`, so the plugin would never appear in the Plugins list.

> **Updating the addon:** disable the plugin (or close the editor) *before* replacing its `.gd` files. Godot hot-reloads changed `@tool` scripts, and reloading this one while it is active — holding the embed control, the Game toolbar and Godot's focus handler out of their normal places — leaves dangling references and can crash the editor. Disable, replace the files, re-enable.

## Usage

Switch to the **3D** workspace and set a 2-viewport layout (or any layout with more than one pane).

Every pane shows a **Game Window** toggle beside its **⋮ Perspective** menu. Click it on the pane you want the game in — that's the whole setup.

The other panes' toggles then disappear, so the one that remains doubles as a label telling you which pane the game belongs to.

That pane is now the **game pane**. Nothing about it changes yet: it stays a fully usable 3D view, with its own menu, gizmos and camera. Press **Play** and the game takes it over; press **Stop** and it hands the pane straight back to 3D.

So the pane is only ever a Game view *while a game is actually running*. There is no blank "waiting" state to look at, no mode to remember you left on, and nothing to toggle before each run — designate the pane once and every Play lands there.

To switch it back off, click the lit **Game Window** toggle again, or the **×** at the left of the game toolbar. To move the game, switch the toggle off and switch it on in another pane.

## Settings

Under **Editor Settings → Game Viewport 3D**:

| Setting | Default | Effect |
| --- | --- | --- |
| `switch_to_3d_on_play` | `true` | Hold the 3D workspace when you press Play, so the Game tab never appears. Turn off to let the editor switch to the Game tab as it normally would. |
| `stretch_to_fit` | `true` | Make the game window fill the pane on first relocation. Turn off to manage the sizing mode yourself. |
| `show_game_toolbar` | `true` | Put the Game view's toolbar in a strip directly above the pane the game runs in. Turn off to leave it in the Game tab. |
| `keep_3d_on_game_focus` | `true` | Detach Godot's focus handler so clicking the game cannot switch workspaces. |
| `hide_game_tab` | `true` | Remove the Game tab from the main-screen selector while Game View is on, making it unreachable. |
| `fullscreen_on_play` | `false` | Expand the game to fill the editor on Play, and drop back on Stop. Rarely needed — captured mouse is handled automatically; this helps games that query absolute cursor positions (see limitations). |

## How it works

Godot already embeds the game process — that's what the Game tab does. Its internal `EmbeddedProcess` control hands its on-screen rect to `DisplayServer.embed_process()`. The only problem is *where* that control lives: inside `GameView`, which the editor hides whenever you leave the Game workspace, and hiding it hides the game.

So this plugin does not reimplement embedding. It:

1. Finds the `EmbeddedProcess` control by walking the editor tree and matching `get_class()`.
2. Creates a host `Control` as a child of the chosen `Node3DEditorViewport` pane, anchored full-rect.
3. Reparents the embedded-process control into that host, and the Game view toolbar into a strip directly above the pane.
4. Hides the pane's own 3D chrome — its `SubViewportContainer` and its overlay layer — **only while the game is running**, so the pane stays a working 3D view the rest of the time. Godot stops rendering a hidden `SubViewport` by itself, so no GPU is spent on the covered scene.
5. Puts everything back on Stop, when Game View is switched off, and on plugin disable.

Play/Stop, the debugger, the remote scene tree and the profiler are untouched — it's the same process the editor launched, just parented elsewhere.

`Node3DEditorViewport` is a plain `Control`, not a `Container`, so a full-rect child follows the pane's position, size and visibility automatically. There is no per-frame layout work, and pane resizes, layout switches and hidden panes are all handled by Godot's own anchoring.

In Godot 4.7 the four panes are not siblings — they are nested in a tree of `SplitContainer`s under `Node3DEditorViewportContainer` — so they are located by a recursive depth-first search, which yields them in the editor's own numbering order.

### The Game Window toggle

Every pane gets a **Game Window** toggle beside its **⋮ Perspective** menu, sharing that menu button's `HBoxContainer` so the row supplies the spacing.

It is a `CheckBox`, so it draws a tick and reserves the tick's area whether ticked or not — it reads as something you switch rather than something you press. Its panel is taken from the neighbouring menu button by copying that button's own resolved styleboxes rather than guessing at them, so it tracks whatever editor theme is in use. That copy matters: the pane's menu button resolves every state to one translucent rounded box, which a default `CheckBox` does not — it would come out opaque, squarer in its padding and visibly foreign next to its neighbour. Any state the menu button does not define falls back to its `normal`, so no state is left looking different from the rest.

Only one pane can host the game at a time, since there is only one embed control — so once a toggle is on, the others hide. That leaves exactly one on screen, and it doubles as the label naming the pane the game lives in. Switch it off and they all come back.

The buttons take no focus (`FOCUS_NONE`). The focus frame described below keys on the pane's overlay holding focus, so a button that grabbed focus on click would darken the very frame it had just switched on.

The row lives in the pane's overlay, which is hidden while a game runs — the toolbar's **×** is the way back out then.

If the chosen pane is not visible — you switched to a 1-viewport layout, or reopened the editor into one — the game is shown in the first visible pane instead of vanishing into a hidden one. The preference is kept, so it returns to the pane you picked as soon as that layout comes back.

### Staying on the 3D workspace

Three separate things pull the editor to the Game workspace, and no editor setting turns any of them off:

- `GameView::_play_pressed`, when you press Play
- the embed completing
- **the game window taking focus** — which happens every single time you click into the running game

The plugin guards against the first two. It connects to the Game view's `visibility_changed` and deselects it **synchronously**, in the same frame it was selected, so the Game tab is never drawn during startup.

The guard is deliberately **bounded**: it runs only from Play until shortly after `embedding_completed`, is rate limited to one switch per 400 ms, and is capped at four switches per play session. Outside that window it is disarmed and the Game tab behaves completely normally.

> **Why it is bounded.** An earlier version held the 3D workspace for the entire play session by re-asserting it every frame. That fights Godot's focus handling: the editor pulls to the Game tab, the plugin yanks back, repeatedly. For a game that captures the mouse this tug-of-war can leave the cursor stranded. The guard no longer works that way.

### Removing the Game tab

The guard above deals with switches it can see coming. The reliable fix is to make the destination unreachable: while Game View is on, the plugin **hides the Game button in the main-screen selector**.

`EditorMainScreen::select()` ignores a request for a main screen whose selector button is hidden. So every switch attempt — Play, embed completion, focus, and anything else — silently does nothing, without the plugin having to know which code path tried. Verified: with Game View on, an explicit `set_main_screen_editor("Game")` leaves `GameView` hidden.

The editor is moved off the Game screen before the button is hidden, since hiding the button of the screen you are on would strand you there. The button is restored when Game View is switched off or the plugin is disabled.

Set `hide_game_tab` to `false` to keep the tab.

### Clicking into the running game

The focus case is additionally **prevented** at its source.

`GameView::_embedded_process_focused` exists only to select the Game workspace when the embedded game takes focus. With the game living in a viewport pane that is exactly backwards: it hides the pane the game is drawn in. So while Game View is on, the plugin **disconnects that handler** and reconnects it on the way out. Nothing to fight, nothing to undo, no focus tug-of-war — the switch simply never fires.

Set `keep_3d_on_game_focus` to `false` to leave Godot's handler alone.

### Keeping the pane usable while idle

The host is a plain `Control` holding only the game, anchored full-rect over the pane. While no game is running the **entire embed subtree** is set to `MOUSE_FILTER_IGNORE`, so clicks fall straight through to the 3D viewport underneath; the original filters are restored the moment a game starts.

It has to be the whole subtree, and this is the subtle part. `EmbeddedProcess` is **not a leaf** — on macOS `EmbeddedProcessMacOS` owns a `LayerHost` child with `MOUSE_FILTER_STOP` spanning the pane — and Godot's `gui_find_control_at_pos` still descends into the children of an `IGNORE` control. `IGNORE` removes only the node it is set on. Setting it on the root alone does nothing whatsoever: the pane looks normal and is completely dead to clicks, camera orbit included.

The subtree is re-walked every frame rather than cached once, because the engine creates and frees those children around embedding.

Because the host is added as the **last** child of the pane, anything left pickable inside it is hit-tested ahead of the pane's own input surface — so this invariant is load-bearing, and the conformance suite asserts it directly.

One consequence worth knowing: when the designated pane is hidden by the current layout, the game moves to the first visible pane. Before the above was fixed, that meant a pane you never designated became unclickable — most visibly in a 1-viewport layout, where it is the only pane there is.

### The game toolbar

The Game view's toolbar is relocated too, and sits in a strip directly above the pane the game runs in — the sizing mode, the scale steps (`1/16×` … `16×`), camera override, suspend and audio mute. Those are Godot's own controls, moved rather than reimplemented, so they keep working exactly as they do in the Game tab. It stays visible even when no game is running, so the controls are findable without starting the game first.

This is where you change the game's size and resolution behaviour: **Game Window Options** for `Fixed Size` / `Keep Aspect Ratio` / `Stretch to Fit`, and the scale menu for a zoom factor.

#### Why it is a sibling of the pane and not a child of it

Putting the toolbar *inside* the pane, stacked above the game, is the obvious layout and it does not work. It insets the embedded control, and Godot's mouse forwarding does not account for that inset — clicks in the running game land off by the toolbar's height.

Godot's own `EmbeddedProcess` has exactly the mechanism that would fix this: a margin that shrinks the game's rect while the control itself stays full-size, so the input mapping stays consistent. A plugin cannot reach it. `EmbeddedProcessBase` and `EmbeddedProcessMacOS` are registered with `ClassDB` but expose no properties and no methods of their own, so there is nothing to call. Layering the toolbar over the game instead does not work either — the embedded game composites above Godot's drawing and simply buries it.

The way out is that the toolbar does not have to be *in* the pane to sit above it. The four panes are nested in a tree of `SplitContainer`s, so the plugin walks up from the pane to the first **vertically oriented** split and inserts the toolbar immediately before the branch the pane lives in. The strip lands directly above that pane, at its full width, and the pane simply shrinks as a whole — the embedded control still fills it exactly, so the game's rect relative to its pane is what it would be with no toolbar at all.

Godot re-orients those splits per viewport layout (the same split is horizontal in the 1-viewport layout and vertical in the stacked 2-viewport one), so the position is recomputed rather than cached, and the strip follows the game when you change layout or move Game View to another pane.

#### The focus frame

Godot outlines the focused pane in orange. With the strip sitting outside the pane, that frame stopped short of it and there was nothing tying the two together — with several panes on screen you could not tell which one the strip drove. The plugin now mirrors the same `FocusViewport` style onto the strip, so both light up together, and the strip stays dark when a *different* pane is focused.

Two different controls draw that frame depending on what the pane is showing, and the strip follows both:

- **While a game runs**, `EmbeddedProcess::_draw()` draws it when `is_process_focused()` holds.
- **The rest of the time** it is the 3D viewport's own focus frame, drawn on the pane's overlay when that overlay has focus.

The test is which control holds the editor's GUI focus. Asking the embedded control's own `has_focus()` — the very thing `is_process_focused()` reads — does not work: `EmbeddedProcessMacOS` has `focus_mode = FOCUS_NONE` and delegates to a `LayerHost` child, so the control itself can only ever answer false and the strip went dark the moment a game started. Its whole subtree is checked instead, which also covers the platforms where the embed control takes focus directly. The overlay is matched exactly rather than by subtree, so focusing the pane's own menu button does not light a frame Godot is not drawing.

The two outlines are joined into one continuous frame rather than drawn as separate boxes. `FocusViewport` is a border-only `StyleBoxFlat` with 4px borders and 5px rounded corners, so joining means opening the facing edges:

- The strip's outline reaches down to the pane's top edge, carrying its side borders straight through the split's 7px drag handle, with its bottom border and bottom corner radii removed.
- The pane's own outline has its top border and top corner radii removed, so it continues the strip's rather than closing under it.

Opening the pane's edge means changing the style Godot itself draws with. `add_theme_stylebox_override` cannot do it — overrides are only consulted when the requested theme type matches the control's own class, and Godot asks for type `EditorStyles`. Theme *resolution*, though, walks up the tree and takes the first owner that has the item, so giving the pane a `Theme` carrying just this one entry shadows it for the pane and everything under it while every other lookup still falls through to the editor theme. That the shadow covers the pane's descendants is exactly right: the embedded game draws the same style from inside the pane, so the playing and not-playing frames both get their top opened.

The join needs the strip to sit directly on top of the pane and span exactly its width. In a 4-viewport layout the strip spans a whole row of two panes, so it falls back to a closed box around the strip and leaves the pane's outline alone.

The joined outline is also drawn **opaque**, which is not cosmetic. The stock border is the accent colour at half alpha, so it takes on whatever is behind it: measured across the seam it rendered 142 over the dark toolbar and 201 over the viewport, and that dull stretch reads as a break even though the line is unbroken. With a game running it would swing further still, since the colour behind that half is then whatever the game draws. The colour used is the stock border composited over the editor's `base_color` — one flat tone end to end that keeps the muted look of the editor's own viewport frames, rather than the accent colour at full opacity, which joins just as cleanly but comes out far more vivid than every other viewport's frame.

Where the frame is parented is not incidental — it has to span two controls that are siblings rather than nested, and neither obvious parent works. The strip is a `MarginContainer` and pins any child to its own rect; `top_level` does **not** exempt a child from that in 4.7. The pane sits inside `Node3DEditorViewportContainer`, which clips, so a frame reaching above the pane is cut off in the layouts where the strip falls outside it. It is therefore parented to the editor's base control — a plain `Panel`, so no layout and no clipping, and an ancestor of both in every layout — and positioned in global coordinates.

Being a child of the split has one consequence worth naming: a `SplitContainer` will resize *any* child to satisfy a drag, so dragging a pane's edge stretched the toolbar instead of the scene. The strip's `custom_maximum_size` is therefore capped at its natural height — Godot skips a child already at its maximum and passes the drag to the next one, so the panes absorb it and the toolbar stays put. (The "no maximum" sentinel is `-1`; setting `0` pins a control to zero size and makes the toolbar vanish.)

Two layouts cannot be served exactly, and both fall back rather than fail:

- **Panes side by side** (2 Viewports Alt, or the top row of a 4-viewport layout): a vertical split can only give a strip spanning a whole row, so the toolbar spans both panes in that row.
- **1 Viewport**: there is no vertical split above the pane at all, so the toolbar goes in the full-width strip above the viewport container.

An **×** button is injected at the left of that toolbar. It is the way back while a game runs: the pane's own overlay — including the **Game Window** toggle — is hidden then, so the control that switched it on is not reachable. If `show_game_toolbar` is `false` there is no toolbar to host that button, so in that case the overlay is deliberately left visible and you use the toggle as usual.

Note that there is no free-form resolution field: Godot's embedded game takes its resolution from your **project's** window settings (`display/window/size/*`), and the toolbar gives you the sizing *mode* and a scale factor on top of that.

### Fullscreen

The toolbar's fullscreen button, immediately left of the trailing **⋮**, gives the game the whole monitor with the editor effectively gone. Three things happen together:

1. Every visible sibling from the game pane **all the way up to the editor root** is hidden: the other viewport panes, the 3D toolbar, the scene tabs, the docks and the title bar. Containers hand their space to whatever stays visible, so the pane expands through Godot's own layout. Nothing is reparented — detaching the host would tear down a live embedding.
2. `EditorInterface.set_distraction_free_mode(true)` hides the docks and the bottom panel.
3. `DisplayServer.window_set_mode(WINDOW_MODE_FULLSCREEN)` puts the editor window itself fullscreen.

Measured coverage: the game goes from **23% of the editor window to 91%**, with the remainder being a 4px window margin and the Game toolbar strip. On a 1920×1080 screen that works out to roughly 95%.

**The Game toolbar is deliberately exempt from the hiding.** The embedded game composites over everything inside its rect, so once it fills the window no editor control underneath it can be clicked. That strip is the only way back out, which is why fullscreen stops just short of total.

Toggling it off restores all three: the previous split, the previous distraction-free state and the previous window mode. It is also cleared automatically when Game View is switched off.

Restoring visibility is not enough on its own, though. A `SplitContainer` re-clamps its offsets against whatever is still visible, so hiding the siblings destroys the proportions and showing them again does not bring them back — the viewport panes and the docks both came back at different sizes than they went in. So every `SplitContainer` between the game pane and the editor root has its offsets recorded **before** anything is hidden, in a pass of its own, and put back on the way out. Leaving fullscreen also resizes the window asynchronously and each resize re-clamps again, so the offsets are re-asserted over the following frames rather than once.

The same applies to the toolbar strip, in both directions. Putting it in the split gives that split another child and it redistributes to make room; taking it out again does not undo that, so switching Game View off left the panes at different sizes than before it was switched on. The split's proportions are captured before the strip joins and put back once it has left — after the removal, since the offsets only mean what they originally meant when the split is back to the same set of visible children.

Joining needs care of its own, because offsets are per dragger and each is measured from that dragger's own default position. Adding the strip adds a dragger, so every later offset lands on the wrong boundary: left alone, the offset that used to separate two panes ended up between the strip and the first pane and squashed it flat, which is why enabling Game View on the *top* pane collapsed it to its minimum while the bottom one behaved. The strip splits one old boundary into two, so both new draggers take that boundary's offset — giving it to only the leading one stretches the strip's slot instead, and since the strip is pinned to its natural height that space is simply lost, leaving the panes short by the offset's whole value. Inserted at the very front there is no boundary to carry over, so a zero goes in and the rest shift along.

The game is composited into the editor window, so there is no way to fullscreen the game process on its own — making the window that hosts it fullscreen is what achieves the same result.

### Making the game fill the pane

Godot's default embedded sizing mode is **Keep Aspect Ratio**, which letterboxes the game inside its container — leaving a strip of the editor viewport visible around it. The plugin selects **Stretch to Fit** instead.

`EmbeddedProcess` exposes no sizing API to scripting, so this is done by driving Godot's own UI: the **Game Window Options** menu item is found by its label and its `id_pressed` signal is emitted, running exactly the handler a click would. Set `stretch_to_fit` to `false` to manage the mode yourself from that menu.

## Compared to Unity

This gets close to Unity's Scene/Game split, but there is a hard architectural difference worth understanding.

In Unity the editor and the game share **one process**, and the Game view is a genuine editor panel that renders into a texture. In Godot the running game is a **separate OS process**. The editor cannot render it into a panel; all it can do is embed that process's native window over a rectangle of the editor.

Everything below follows from that and cannot be fixed by an addon:

- The game draws **on top of** its rectangle. Editor gizmos and overlays cannot composite over it.
- Focus behaves like a separate window, because it is one. That is why the workspace guard above is needed at all.
- Sizing is the game window's own, hence the Stretch to Fit handling rather than free-form scaling.
- The game hides when you leave the 3D workspace, just as it does when you leave the Game tab.

A true in-panel Game view would require engine-level changes to Godot, not a plugin.

### Why relocation happens on toggle, not on Play

Reparenting fires `EXIT_TREE` / `ENTER_TREE` on the control, which can tear down a live embedding. The control is therefore moved while nothing is running, and Play embeds into a node that already sits in the 3D viewport.

For the same reason, toggling the plugin off or changing the target pane **while the game is running** is queued rather than applied immediately. The toolbar says `Applies when you stop the game`. Stop the game and the change takes effect.

## Verified against Godot 4.7.1.stable (macOS)

Confirmed by introspecting a live editor instance:

- `EmbeddedProcessMacOS` exists and is a `Control`; its home is `Panel < GameView < WindowWrapper < MainScreen`
- Relocation places it at `GameViewport3DHost < Node3DEditorViewport`, with the host's rect exactly equal to the pane's
- Changing the target pane moves it correctly between slots
- Disabling restores it to its original parent, at its original index
- No errors or warnings are emitted during any of the above

Not covered by that test: the embedding of an actually running game, which needs a real windowing session rather than a headless one.

## Limitations

- **Uses undocumented editor internals** (`EmbeddedProcess`, `Node3DEditorViewportContainer`, `Node3DEditorViewport`). These are located by class name and only generic `Node`/`Control` API is called on them, but a future Godot release could rename them. The plugin fails soft: the toolbar reports the problem and the editor keeps working.
- **On macOS the game is a child OS window floating over the viewport rect.** It draws on top of everything in that rect, so editor gizmos and overlays will not composite over the game. This is the same limitation the built-in Game tab has.
- **The game hides when you leave the 3D workspace**, exactly as it hides when you leave the Game tab. Switch back to 3D and it reappears.
- **While relocated, the Game tab is empty** apart from a notice explaining where the game went.
- **Games that capture the mouse work in any pane — via an active fix in this plugin.** When the embedded game captures the mouse, the editor applies that capture to the *whole editor window*: macOS hides the cursor and pins it at the window's centre, and every subsequent mouse event carries that pinned position. The editor routes mouse events by position, so unless the game's pane happened to contain the window centre, every event landed on whatever control sat there instead and the game went deaf — a pane in the top half of the window was uncontrollable. The pinned cursor cannot be moved into the pane (`DisplayServer.warp_mouse` is an explicit no-op while captured), so the plugin fixes the routing instead: in `Node._input`, ahead of GUI routing, mouse events falling outside the embedded control are rewritten onto it while a capture is active — captured events onto its centre, mirroring the engine's own pin; confined-hidden events clamped, since those still use absolute positions. Mouse-look reads `relative`, which is untouched, and events already inside the pane are never modified. Verified end to end: with events injected at the pin point, the game received none without the redirect and all of them — deltas intact — with it. The Output panel logs `Game Viewport 3D: game captured the mouse` when the redirect engages.
- **Games that query absolute cursor positions while not captured still read wrong values** (macOS): the embedded game is told its window sits at `(0, 0)` and `DisplayServer.mouse_get_position()` returns values in the wrong space. This is an engine issue reproduced on the stock Game tab with this plugin disabled — see [#109597](https://github.com/godotengine/godot/issues/109597) and [#107819](https://github.com/godotengine/godot/issues/107819). Event-driven positions delivered to the game are correct; only direct queries are wrong. `fullscreen_on_play` mitigates this case by moving the pane next to the window origin.
- If the chosen pane is hidden (for example the 1-viewport layout), the toolbar warns `Viewport N is hidden — use a 2+ viewport layout` and nothing is displayed until you pick a visible pane.

## Files

| File | Role |
| --- | --- |
| `plugin.gd` | `EditorPlugin` entry point; relocation lifecycle, play/stop handling, settings |
| `editor_internals.gd` | Locates editor-internal nodes by class name |
| `LICENSE` | MIT |

## License

MIT — see `LICENSE`.
