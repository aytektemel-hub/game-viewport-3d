@tool
extends EditorPlugin

## Game Viewport 3D
##
## Turns a pane of the 3D editor's split viewport into a Game view. Every pane
## offers a "Game Window" toggle beside its "⋮ Perspective" menu; switch one on
## and the running game takes that pane over, along with the Game view's
## toolbar, and switching it off gives the pane back.
##
## The embedding itself is still done entirely by Godot — this plugin only
## relocates the controls that own it.

# Relative, so a misplaced install parses cleanly instead of erroring — though
# Godot only discovers plugins under res://addons/, so the folder still has to
# end up at res://addons/game_viewport_3d/ to be enabled.
const Internals := preload("editor_internals.gd")

const SETTING_PREFIX := "game_viewport_3d/"
const MAIN_SCREEN_3D := "3D"

## Text of the per-pane toggle that picks which viewport hosts the game.
const PANE_TOGGLE_TEXT := "Game Window"

## Editor settings game embedding cannot work without.
const SETTING_EMBED_MODE := "run/window_placement/game_embed_mode"
const EMBED_MODE_EMBED := 1
const SETTING_SINGLE_WINDOW := "interface/editor/display/single_window_mode"
const SETTING_MULTI_WINDOW := "interface/multi_window/enable"

## Label of the Game entry in the main-screen selector.
const GAME_SCREEN_LABEL := "Game"

## The style Godot draws around the focused embedded game, mirrored onto the
## toolbar strip so the two read as one unit.
const FOCUS_STYLEBOX := "FocusViewport"
const FOCUS_STYLEBOX_TYPE := "EditorStyles"


## Label of the Game Window Options item that makes the embedded game fill its
## container instead of letterboxing inside it.
const STRETCH_ITEM_TEXT := "Stretch to Fit"

## The workspace guard is deliberately bounded. Godot pulls the editor to the
## Game workspace whenever the embedded game takes focus, and continuously
## fighting that causes a focus tug-of-war which can strand the mouse cursor —
## badly so for games that capture the mouse.
const GUARD_TIMEOUT_MSEC := 3000
const GUARD_GRACE_MSEC := 500
const SWITCH_MIN_INTERVAL_MSEC := 400
const MAX_SWITCHES_PER_SESSION := 4

## Idle frames between attempts to locate the editor-internal nodes.
const RESOLVE_RETRY_FRAMES := 60

## A plugin instance that loads within this many engine frames is part of the
## editor booting, not a user activating it from the Plugins list.
const ACTIVATION_BOOT_FRAMES := 120

## Frames over which split proportions are re-asserted after being put back, to
## outlast the resorts that follow — a window resize on leaving fullscreen, or
## the split re-clamping after a child is added or removed.
const SPLIT_RESTORE_FRAMES := 20

var _host: Control
var _notice: Label
var _exit_button: Button
var _fullscreen_button: Button
var _fullscreen := false
var _fullscreen_hidden: Array[Control] = []
## `[[SplitContainer, offsets], ...]` captured before fullscreen hides anything.
var _fullscreen_splits: Array = []
## Proportions waiting to be put back, re-asserted for a few frames.
var _split_restore: Array = []
var _split_restore_frames := 0
var _fullscreen_prev_window_mode := -1
var _fullscreen_prev_distraction := false


var _viewport_container: Control
var _viewports: Array[Control] = []
var _game_view: Control
var _embedded: Control
var _game_toolbar: Control

var _origin_parent: Node
var _origin_index := -1
var _origin_h_flags := 0
var _origin_v_flags := 0
var _origin_mouse_filter := Control.MOUSE_FILTER_STOP
## Original `mouse_filter` of every Control below the embed control, keyed by
## instance id.
var _embed_child_filters := {}

var _toolbar_origin_parent: Node
var _toolbar_origin_index := -1
var _toolbar_origin_max_size := Vector2(-1, -1)
var _toolbar_relocated := false
## The split the strip currently sits in, and its proportions from before the
## strip was put there.
var _toolbar_split: SplitContainer
## Deliberately untyped: `get_split_offsets()` returns a `PackedInt32Array`, and
## a statically-typed `Array` would coerce it on assignment, after which it no
## longer compares equal to a freshly read one.
var _toolbar_split_offsets = []
var _toolbar_frame: Control
var _toolbar_frame_lit := false
var _toolbar_frame_joined := false
var _frame_box_open_bottom: StyleBoxFlat
var _frame_box_source: StyleBox
var _pane_frame_target: Control
var _pane_frame_prev_theme: Theme
var _pane_frame_source: StyleBox
## Slot index -> its "Game Window" toggle.
var _pane_toggles := {}

## The pane whose 3D chrome is currently hidden, and what was hidden.
var _chrome_render: Control
var _chrome_overlay: Control

var _relocated := false
var _applied_slot := -1
## One layout auto-switch per activation, so a failed attempt cannot loop.
var _auto_layout_tried := false
## Engine frame count when this instance loaded: near zero when the editor is
## booting with the plugin already enabled, large when the user just switched
## it on in the Plugins list.
var _frames_at_load := 0
var _activation_layout_checked := false
var _prereq_checked := false
var _prereq_dialog: ConfirmationDialog

var _want_relocated := false
var _slot := 1
var _switch_to_3d := true
var _stretch_to_fit := true
var _show_game_toolbar := true
var _keep_3d_on_game_focus := true
var _hide_game_tab := true
var _fullscreen_on_play := false

var _suppressed_focus_callable := Callable()
var _game_screen_button: Button
## Set once the selector button cannot be found, so the search — a walk of the
## whole editor tree — is not repeated on every idle frame.
var _game_tab_lookup_failed := false

var _was_playing := false
var _guard_end_msec := 0
var _last_switch_msec := 0
var _switch_count := 0
var _resolve_cooldown := 0
var _last_status := ""

## Test hook: forces the captured-mouse redirect on. A real capture cannot be
## engaged safely from an automated editor run, so tests set this instead.
var _force_capture_redirect := false
var _capture_redirect_was := false


func _enter_tree() -> void:
	# The strip placement drives Godot 4.7's multi-child `SplitContainer` API;
	# older editors lay out only the first two children of a split, which would
	# leave the toolbar overlapping the panes. Decline cleanly instead of
	# half-working.
	var v := Engine.get_version_info()
	if v["major"] < 4 or (v["major"] == 4 and v["minor"] < 7):
		push_warning("Game Viewport 3D: requires Godot 4.7 or newer - the plugin is inactive.")
		return
	_frames_at_load = Engine.get_process_frames()
	_define_settings()
	_load_settings()
	EditorInterface.get_editor_settings().settings_changed.connect(_load_settings)
	set_process(true)
	set_process_input(true)


func _exit_tree() -> void:
	set_process(false)

	var settings := EditorInterface.get_editor_settings()
	if settings.settings_changed.is_connected(_load_settings):
		settings.settings_changed.disconnect(_load_settings)

	_uninstall_pane_toggles()
	if is_instance_valid(_prereq_dialog):
		_prereq_dialog.queue_free()
	_prereq_dialog = null
	_show_game_main_screen()
	_restore_game_focus_switch()
	_disconnect_embed_signals()
	if is_instance_valid(_game_view) and _game_view.visibility_changed.is_connected(_on_game_view_visibility_changed):
		_game_view.visibility_changed.disconnect(_on_game_view_visibility_changed)

	# Always hand the controls back, even mid-play — leaving them parented
	# under a freed plugin would break the Game tab permanently.
	_restore()


func _process(_delta: float) -> void:
	var playing := EditorInterface.is_playing_scene()

	# Handled before anything can bail out: chrome hidden when the game started
	# has to come back even if node resolution fails afterwards, or the pane is
	# stranded blank with no way to recover.
	if not playing and _was_playing:
		_on_play_stopped()
		_was_playing = false

	# Checked before node resolution on purpose: with the wrong settings the
	# embed control never resolves, and this dialog is the way out.
	if not _prereq_checked:
		_prereq_checked = true
		if _frames_at_load > ACTIVATION_BOOT_FRAMES:
			_show_prereq_dialog()

	if not _resolve_nodes():
		return

	# Freshly activated from the Plugins list in a 1-viewport layout: grow the
	# layout to two right away, so both panes offer their Game Window toggle
	# and the user just picks one. Deliberately NOT done when the editor boots
	# with the plugin already enabled — forcing a layout change on every start
	# would fight whatever the user set up.
	if not _activation_layout_checked:
		_activation_layout_checked = true
		if _frames_at_load > ACTIVATION_BOOT_FRAMES and _visible_pane_count() < 2:
			_switch_to_two_viewports()

	_reconcile(playing)

	if playing and not _was_playing:
		_on_play_started()
	_was_playing = playing

	if _split_restore_frames > 0:
		_split_restore_frames -= 1
		_restore_split_offsets()
		if _split_restore_frames == 0:
			_split_restore.clear()

	if _guard_armed():
		_keep_3d_selected()
	elif _guard_end_msec > 0:
		_guard_end_msec = 0

	# Logged on transition so a broken activation signal is diagnosable from
	# the Output panel alone.
	var redirecting := _capture_redirect_active()
	if redirecting != _capture_redirect_was:
		_capture_redirect_was = redirecting
		if redirecting:
			print("Game Viewport 3D: game captured the mouse - redirecting mouse input into the game pane")
		else:
			print("Game Viewport 3D: mouse capture ended")


## Keeps the game controllable while it holds the mouse captured.
##
## When the embedded game captures the mouse, the editor applies the capture to
## the whole editor window: macOS hides the cursor and pins it at the centre of
## the window's content view, and every mouse event from then on carries that
## pinned position. The editor routes mouse events by position, so unless the
## game's pane happens to contain the window centre, every event lands on
## whatever control sits there instead and the game goes deaf — a pane in the
## top half of the window was uncontrollable, and one covering the centre
## worked only by luck.
##
## The pinned cursor cannot be moved into the pane: `DisplayServer.warp_mouse`
## is an explicit no-op while the display server is captured, and re-applying
## the capture re-warps to the window centre. So the routing is fixed instead
## of the cursor. This runs in `Node._input`, before GUI routing, and while
## capture is active it rewrites the position of any mouse event that falls
## outside the embedded control onto that control — GUI routing then delivers
## the event to the embedded control, which forwards it to the game exactly as
## if the cursor had been pinned inside the pane. Mouse-look reads `relative`,
## which is left untouched.
##
## Captured events are rewritten onto the control's centre, mirroring where
## the engine pins the cursor. Confined-hidden events are clamped instead,
## since those games still read absolute positions. Events already inside the
## control are never touched, so a pane that does contain the pinned cursor
## behaves exactly as it always did.
func _input(event: InputEvent) -> void:
	var mouse := event as InputEventMouse
	if mouse == null:
		return
	if not _capture_redirect_active():
		return
	var rect := _embedded.get_global_rect()
	if rect.has_point(mouse.position):
		return
	var target := rect.get_center()
	if Input.mouse_mode == Input.MOUSE_MODE_CONFINED_HIDDEN:
		target = mouse.position.clamp(rect.position, rect.end - Vector2.ONE)
	mouse.global_position = target
	mouse.position = target


## The redirect is active only while the game runs in the relocated pane with
## the mouse captured. The editor's own mouse mode is the signal: the capture
## the game requests is applied to the editor's display server, so it is
## directly observable here.
func _capture_redirect_active() -> bool:
	if not _relocated or not is_instance_valid(_embedded) or not _embedded.is_visible_in_tree():
		return false
	if not EditorInterface.is_playing_scene():
		return false
	if _force_capture_redirect:
		return true
	var mode := Input.mouse_mode
	return mode == Input.MOUSE_MODE_CAPTURED or mode == Input.MOUSE_MODE_CONFINED_HIDDEN


# --- State reconciliation --------------------------------------------------


## Moving the controls detaches them from the tree, which would tear down a
## live embedding, so changes are deferred until playback stops.
func _reconcile(playing: bool) -> void:
	if not _want_relocated:
		if _relocated and not playing:
			_restore()
		return

	var target := _effective_slot()
	if not _relocated:
		if not playing:
			_relocate(target)
	elif _applied_slot != target and not playing:
		_move_to(target)

	if _relocated and _toolbar_relocated and is_instance_valid(_game_toolbar):
		_game_toolbar.visible = _show_game_toolbar
		_place_game_toolbar()
		_update_toolbar_frame()

	if _relocated and is_instance_valid(_embedded):
		_set_embed_picking(playing)

	if _relocated:
		_enforce_game_tab_hidden()


## Makes the relocated embed control click-through while no game is running, so
## the pane underneath stays a usable 3D view.
##
## This must cover the whole subtree, not just the root. `EmbeddedProcess` is
## not a leaf: on macOS `EmbeddedProcessMacOS` owns a `LayerHost` child with
## `MOUSE_FILTER_STOP` spanning the pane, and Godot's `gui_find_control_at_pos`
## still descends into the children of an `IGNORE` control — `IGNORE` removes
## only the node it is set on. Setting it on the root alone did nothing at all.
##
## The subtree is re-walked every frame rather than cached, because the engine
## creates and frees those children around embedding.
func _set_embed_picking(playing: bool) -> void:
	_embedded.mouse_filter = _origin_mouse_filter if playing else Control.MOUSE_FILTER_IGNORE
	for node in Internals.find_all(_embedded, func(n: Node) -> bool: return n is Control):
		var control := node as Control
		var id := control.get_instance_id()
		if not _embed_child_filters.has(id):
			_embed_child_filters[id] = control.mouse_filter
		control.mouse_filter = _embed_child_filters[id] if playing else Control.MOUSE_FILTER_IGNORE



# --- Lifecycle -------------------------------------------------------------


func _on_play_started() -> void:
	if not _relocated:
		return
	# The pane is an ordinary 3D view until now; the game takes it over only
	# for as long as it is actually running.
	var viewport := _viewport_at(_applied_slot)
	if viewport != null:
		_hide_pane_chrome(viewport)

	# Godot maps the embedded game's mouse as though its pane sat at the
	# editor window's origin, so the error is the pane's offset within that
	# window — which is why a small, low pane leaves the cursor outside the
	# game. Fullscreen shrinks that offset to nearly nothing, so games that
	# read the cursor or capture it stay usable. See the README's limitations.
	if _fullscreen_on_play and not _fullscreen:
		_fullscreen = true
		if is_instance_valid(_fullscreen_button):
			_fullscreen_button.set_pressed_no_signal(true)
		_apply_fullscreen()

	_switch_count = 0
	_guard_end_msec = Time.get_ticks_msec() + GUARD_TIMEOUT_MSEC
	_keep_3d_selected()


func _on_play_stopped() -> void:
	_guard_end_msec = 0
	# Hand the pane straight back to 3D.
	_clear_fullscreen()
	_fullscreen = false
	if is_instance_valid(_fullscreen_button):
		_fullscreen_button.set_pressed_no_signal(false)
	_show_pane_chrome()
	# The Game tab stays hidden: it is owned by Game View being on, not by
	# playback. Showing it here made it reappear the moment the game stopped.


func _guard_armed() -> bool:
	return _guard_end_msec > 0 and Time.get_ticks_msec() < _guard_end_msec


## Rate limited and capped per play session: switching the main screen while
## the game holds focus can start a tug-of-war with Godot, and an unbounded
## version of this is what made the mouse cursor stick.
func _keep_3d_selected() -> void:
	if not _relocated or not _switch_to_3d:
		return
	if not is_instance_valid(_game_view) or not _game_view.is_visible_in_tree():
		return
	var now := Time.get_ticks_msec()
	if now - _last_switch_msec < SWITCH_MIN_INTERVAL_MSEC:
		return
	if _switch_count >= MAX_SWITCHES_PER_SESSION:
		return
	_last_switch_msec = now
	_switch_count += 1
	EditorInterface.set_main_screen_editor(MAIN_SCREEN_3D)


func _on_game_view_visibility_changed() -> void:
	if _guard_armed():
		_keep_3d_selected()


func _on_embedding_completed() -> void:
	if not _relocated or not _switch_to_3d:
		return
	_guard_end_msec = Time.get_ticks_msec() + GUARD_GRACE_MSEC
	_keep_3d_selected()


## Only a fallback. Normally `_suppress_game_focus_switch` has already stopped
## the switch from happening, which is far better than undoing it afterwards.
func _on_embedded_process_focused() -> void:
	if _keep_3d_on_game_focus and not _suppressed_focus_callable.is_valid():
		_keep_3d_selected()


## Stops clicking into the running game from yanking the editor to the Game
## tab, by detaching `GameView`'s own handler for the duration.
##
## `GameView::_embedded_process_focused` exists only to select the Game
## workspace when the embedded game takes focus. With the game living in a 3D
## viewport pane that is exactly wrong — it hides the pane the game is drawn
## in. Removing the cause is much safer than reacting to it: an earlier version
## counter-switched back to 3D afterwards, which fought Godot's focus handling
## and could strand the mouse cursor for games that capture it.
func _suppress_game_focus_switch() -> void:
	if _suppressed_focus_callable.is_valid():
		return
	if not _keep_3d_on_game_focus:
		return
	if not is_instance_valid(_embedded) or not _embedded.has_signal("embedded_process_focused"):
		return
	for connection in _embedded.embedded_process_focused.get_connections():
		var callable: Callable = connection["callable"]
		if callable.get_object() == _game_view:
			_suppressed_focus_callable = callable
			_embedded.embedded_process_focused.disconnect(callable)
			return


## Removes the Game tab from the main-screen selector while Game View is on.
##
## This is the real fix for "clicking the game sends me to the Game tab".
## Rather than guessing which code path performs the switch and countering it,
## the destination is made unreachable: `EditorMainScreen::select()` ignores a
## request for a main screen whose selector button is hidden, so every switch
## attempt — Play, embed completion, focus — silently does nothing.
##
## It is hidden for as long as Game View is on, not just while the game runs.
## With the game drawn in a 3D pane the tab has nothing left to show, and a tab
## that vanishes on Play only to come back on Stop reads as a glitch.
##
## The editor is moved off the Game screen first, since hiding the button of
## the screen you are currently on would leave it selected and blank.
func _hide_game_main_screen() -> void:
	if not _hide_game_tab or is_instance_valid(_game_screen_button):
		return
	var base := EditorInterface.get_base_control()
	if base == null:
		return
	var button := Internals.find_main_screen_button(base, GAME_SCREEN_LABEL)
	if button == null:
		_game_tab_lookup_failed = true
		_set_status("Game main-screen button not found")
		return
	if is_instance_valid(_game_view) and _game_view.is_visible_in_tree():
		EditorInterface.set_main_screen_editor(MAIN_SCREEN_3D)
	_game_screen_button = button
	_game_screen_button.hide()


## Re-asserts the hidden state every frame Game View is on.
##
## The button belongs to the editor, which shows it again on its own — a
## feature-profile change is one such moment — so hiding it once is not enough.
## Re-asserting costs nothing: the button is cached after the first search, so
## the common path here is a single visibility check, and the tree walk is not
## retried once it has come up empty.
func _enforce_game_tab_hidden() -> void:
	if not _hide_game_tab:
		return
	if is_instance_valid(_game_screen_button):
		if _game_screen_button.visible:
			_game_screen_button.hide()
		return
	if _game_tab_lookup_failed:
		return
	_hide_game_main_screen()


func _show_game_main_screen() -> void:
	if is_instance_valid(_game_screen_button):
		_game_screen_button.show()
	_game_screen_button = null
	_game_tab_lookup_failed = false


func _restore_game_focus_switch() -> void:
	if not _suppressed_focus_callable.is_valid():
		return
	if is_instance_valid(_embedded) and _embedded.has_signal("embedded_process_focused"):
		if not _embedded.embedded_process_focused.is_connected(_suppressed_focus_callable):
			_embedded.embedded_process_focused.connect(_suppressed_focus_callable)
	_suppressed_focus_callable = Callable()


func _on_embedding_failed() -> void:
	_set_status("Godot failed to embed the game")


# --- Relocation ------------------------------------------------------------


func _relocate(slot: int) -> void:
	if _relocated or not is_instance_valid(_embedded):
		return

	# A 1-viewport layout grows a second pane before the game moves in — the
	# whole point is editing in one pane while the game runs in the other.
	# The game then takes the bottom pane, leaving the pane that was being
	# edited on top. One attempt per activation; if the layout cannot be
	# switched, fall through and use the single visible pane as before.
	if _visible_pane_count() < 2 and not _auto_layout_tried:
		_auto_layout_tried = true
		if _switch_to_two_viewports():
			_set_slot(1)
			return

	var viewport := _viewport_at(slot)
	if viewport == null:
		return

	_create_host(viewport)
	if not is_instance_valid(_host):
		return

	_origin_parent = _embedded.get_parent()
	_origin_index = _embedded.get_index()
	_origin_h_flags = _embedded.size_flags_horizontal
	_origin_v_flags = _embedded.size_flags_vertical
	_origin_mouse_filter = _embedded.mouse_filter

	# The game fills the entire pane, so its rect starts at the pane's top
	# edge. The toolbar goes outside the pane rather than inset into it —
	# see `_relocate_game_toolbar`.
	_embedded.reparent(_host, false)
	_embedded.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Set before relocating the toolbar: `_toolbar_anchor` resolves the strip's
	# position from the pane the game is applied to.
	_relocated = true
	_applied_slot = slot

	_relocate_game_toolbar()
	_suppress_game_focus_switch()
	_show_notice()
	_apply_stretch_to_fit()
	_update_pane_toggles()
	_auto_layout_tried = false


func _restore() -> void:
	if not _relocated:
		_destroy_host()
		return
	_relocated = false
	_applied_slot = -1

	_auto_layout_tried = false
	_clear_fullscreen()
	_fullscreen = false
	_show_pane_chrome()
	_show_game_main_screen()
	_restore_game_focus_switch()
	_hide_notice()
	_restore_game_toolbar()

	if is_instance_valid(_embedded) and is_instance_valid(_origin_parent):
		_embedded.reparent(_origin_parent, false)
		_origin_parent.move_child(_embedded, clampi(_origin_index, 0, _origin_parent.get_child_count() - 1))
		_embedded.size_flags_horizontal = _origin_h_flags
		_embedded.size_flags_vertical = _origin_v_flags
		_set_embed_picking(true)
		_embed_child_filters.clear()
		_embedded.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_destroy_host()
	_update_pane_toggles()


func _move_to(slot: int) -> void:
	var viewport := _viewport_at(slot)
	if viewport == null or not is_instance_valid(_host):
		return
	_clear_fullscreen()
	_show_pane_chrome()
	_host.reparent(viewport, false)
	_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_applied_slot = slot
	_place_game_toolbar()
	if EditorInterface.is_playing_scene():
		_hide_pane_chrome(viewport)
	if _fullscreen:
		_apply_fullscreen()
	_update_pane_toggles()


# --- Pane chrome -----------------------------------------------------------


## Blanks the pane's own 3D content so only the game shows: the render
## container and the overlay layer (view menu, info readout, rotation gizmo).
##
## Only visibility is touched. Godot already stops a hidden `SubViewport` from
## rendering and restores it when shown, so managing `render_target_update_mode`
## here as well is redundant — and an earlier version that did so raced with
## Godot's own handling and could leave a pane stuck on `UPDATE_DISABLED`,
## permanently frozen and grey.
##
## The overlay is only hidden when the Game view toolbar is available to host
## the exit button — otherwise the "⋮ Perspective" menu must stay reachable, or
## there would be no way to switch Game View back off.
func _hide_pane_chrome(viewport: Control) -> void:
	_show_pane_chrome()

	_chrome_render = Internals.find_viewport_render(viewport)
	if is_instance_valid(_chrome_render):
		_chrome_render.hide()

	if is_instance_valid(_exit_button):
		_chrome_overlay = Internals.find_viewport_overlay(viewport)
		if is_instance_valid(_chrome_overlay):
			_chrome_overlay.hide()


func _show_pane_chrome() -> void:
	if is_instance_valid(_chrome_render):
		_chrome_render.show()
	if is_instance_valid(_chrome_overlay):
		_chrome_overlay.show()
	_chrome_render = null
	_chrome_overlay = null


# --- Host ------------------------------------------------------------------


## `Node3DEditorViewport` is a plain Control, not a Container, so a full-rect
## child tracks the pane's position, size and visibility on its own.
func _create_host(viewport: Control) -> void:
	if is_instance_valid(_host):
		_host.reparent(viewport, false)
	else:
		_host = Control.new()
		_host.name = "GameViewport3DHost"
		_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_host.clip_contents = true
		viewport.add_child(_host)
	_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _destroy_host() -> void:
	if is_instance_valid(_host):
		# Safety net: freeing the host would free the editor's embed control
		# with it, permanently breaking the Game tab.
		if is_instance_valid(_embedded) and _embedded.get_parent() == _host:
			_host.remove_child(_embedded)
			if is_instance_valid(_origin_parent):
				_origin_parent.add_child(_embedded)
		_host.queue_free()
	_host = null
	_exit_button = null


## The pane that will actually host the game: the chosen one when it is
## visible, otherwise the first visible pane.
##
## Switching the 3D editor to a layout that hides the chosen pane would
## otherwise strand the game in a hidden pane, where it simply vanishes with no
## indication. The preference itself is left untouched, so the game returns to
## the chosen pane as soon as that layout comes back.
func _effective_slot() -> int:
	var chosen := _viewport_at(_slot)
	if chosen != null and chosen.is_visible_in_tree():
		return _slot
	for i in _viewports.size():
		var candidate := _viewport_at(i)
		if candidate != null and candidate.is_visible_in_tree():
			return i
	# Nothing is visible: the 3D workspace is not the active main screen. Stay
	# put rather than reparenting the host on every workspace switch.
	return _applied_slot if _relocated else _slot


## Counts panes the current viewport layout shows. The pane's own `visible`
## flag is what the layout controls, and unlike `is_visible_in_tree()` it stays
## meaningful while another main screen covers the 3D editor entirely.
func _visible_pane_count() -> int:
	var count := 0
	for i in _viewports.size():
		var pane := _viewport_at(i)
		if pane != null and pane.visible:
			count += 1
	return count


## Switches the 3D editor to the stacked 2-viewport layout by driving Godot's
## own View-menu item — the same handler a click on "2 Viewports" runs.
##
## The items are matched by their English labels, so a translated editor UI
## will not match; the plugin then simply keeps the single visible pane, which
## is the pre-existing behaviour rather than a failure.
func _switch_to_two_viewports() -> bool:
	var menu := Internals.find_layout_menu(EditorInterface.get_base_control())
	if menu == null:
		_set_status("viewport-layout menu not found - using the visible pane")
		return false
	for i in menu.item_count:
		if menu.get_item_text(i) == "2 Viewports":
			menu.id_pressed.emit(menu.get_item_id(i))
			return true
	return false


func _viewport_at(slot: int) -> Control:
	if slot < 0 or slot >= _viewports.size():
		return null
	var viewport := _viewports[slot]
	return viewport if is_instance_valid(viewport) else null


# --- Game toolbar ----------------------------------------------------------


## Moves the Game view's toolbar into a strip directly above the game's pane,
## and injects an exit button so Game View can be switched off once the pane's
## own menu is hidden.
##
## It sits above the viewports but *outside* the panes, and that distinction is
## the whole design. Three constraints box it in:
##
##  - The game must fill its pane exactly. Stacking a toolbar above it inside
##    the pane insets the embedded control, and Godot's mouse forwarding does
##    not account for that inset — clicks in the game land off by the toolbar's
##    height.
##  - Godot's own `EmbeddedProcess` has a margin mechanism that would inset the
##    game's rect while leaving the control full-size, which keeps its input
##    mapping consistent. It is unreachable: `EmbeddedProcessBase` and
##    `EmbeddedProcessMacOS` register with ClassDB exposing no properties and
##    no methods of their own, so a plugin cannot set those margins.
##  - The embedded game is composited *above* Godot's own drawing, so a toolbar
##    layered over the game's rect is simply buried behind it, regardless of
##    child order.
##
## So the toolbar becomes a *sibling* of the pane's branch instead of a child of
## the pane — see `_toolbar_anchor`. It ends up directly above the pane, full
## pane width, while the pane merely shrinks as a whole. The embedded control
## still fills its pane exactly, so its geometry relative to the pane is what it
## would be with no toolbar at all and the click mapping is unaffected. It is
## clear of the game's rect and stays visible in fullscreen.
func _relocate_game_toolbar() -> void:
	if not _show_game_toolbar or _toolbar_relocated:
		return
	if not is_instance_valid(_game_toolbar):
		_game_toolbar = Internals.find_game_toolbar(_game_view)
	if not is_instance_valid(_game_toolbar):
		_set_status("Game toolbar not found")
		return
	# Resolved before detaching, so a toolbar that has nowhere to go is left
	# where it is rather than orphaned.
	if _toolbar_anchor().is_empty():
		_set_status("no place found for the Game toolbar")
		return

	_toolbar_origin_parent = _game_toolbar.get_parent()
	_toolbar_origin_index = _game_toolbar.get_index()
	_toolbar_origin_max_size = _game_toolbar.custom_maximum_size
	_toolbar_origin_parent.remove_child(_game_toolbar)
	_toolbar_relocated = true
	_place_game_toolbar()
	_inject_toolbar_buttons()
	_create_toolbar_frame()


## Where the toolbar strip belongs: `[container, branch]`, the branch being the
## child of `container` that the game's pane lives under. The toolbar is
## inserted immediately before it.
##
## The target is the first *vertically* oriented `SplitContainer` above the
## pane, which puts the strip directly above that pane and nothing else. Godot
## re-orients these splits per viewport layout — the same split is horizontal in
## the 1-viewport layout and vertical in the stacked 2-viewport one — so this is
## recomputed rather than cached.
##
## When no vertical split sits above the pane (the 1-viewport layout, or panes
## placed side by side) there is no strip that spans just this pane, so it falls
## back to the full-width strip above the whole viewport container.
func _toolbar_anchor() -> Array:
	var pane := _viewport_at(_applied_slot)
	if pane == null:
		return []
	var branch: Node = pane
	var parent: Node = pane.get_parent()
	while parent != null and parent != _viewport_container:
		if parent is SplitContainer and (parent as SplitContainer).vertical:
			return [parent, branch]
		branch = parent
		parent = parent.get_parent()
	if is_instance_valid(_viewport_container):
		var above := _viewport_container.get_parent()
		if above != null:
			return [above, _viewport_container]
	return []


## Moves the strip to wherever the game's pane is now. Idempotent and cheap —
## a few parent hops and an index compare — so it can run every frame, which is
## what keeps the strip attached to the right pane when the viewport layout
## changes underneath it.
func _place_game_toolbar() -> void:
	if not _toolbar_relocated or not is_instance_valid(_game_toolbar):
		return
	_pin_toolbar_height()
	var anchor := _toolbar_anchor()
	if anchor.is_empty():
		return
	var parent: Node = anchor[0]
	var branch: Node = anchor[1]
	if _game_toolbar.get_parent() == parent and _game_toolbar.get_index() == branch.get_index() - 1:
		return
	if _game_toolbar.get_parent() != null:
		_game_toolbar.get_parent().remove_child(_game_toolbar)
		_release_toolbar_split()
	_capture_toolbar_split(parent)
	parent.add_child(_game_toolbar)
	# Appending leaves `branch` where it was, so its index is the slot the
	# toolbar has to take to sit immediately in front of it.
	parent.move_child(_game_toolbar, branch.get_index())
	_seat_toolbar_offsets(parent)


## Caps the strip at its natural height so dragging a pane edge resizes the
## pane and not the toolbar.
##
## A `SplitContainer` will resize *any* child to satisfy a drag, and the strip
## now sits between two panes, so grabbing a pane's edge stretched the toolbar
## instead of the scene. Godot's own splitting logic skips a child that is
## already at its maximum and passes the drag to the next one, so capping the
## height at the minimum takes the toolbar out of the drag entirely.
##
## `-1` is the "no maximum" sentinel. `0` does *not* mean "unlimited" — it pins
## the control to zero size, which collapses the toolbar completely.
##
## Recomputed rather than set once, because the natural height follows the
## editor theme and scale.
func _pin_toolbar_height() -> void:
	var wanted := Vector2(-1, _game_toolbar.get_combined_minimum_size().y)
	if not _game_toolbar.custom_maximum_size.is_equal_approx(wanted):
		_game_toolbar.custom_maximum_size = wanted


## Mirrors the focus frame Godot draws around the running game onto the toolbar
## strip, so it is obvious which pane the strip belongs to.
##
## Two different controls draw that frame, and the strip has to follow both:
##
##  - While a game runs, `EmbeddedProcess::_draw` draws it when the game process
##    holds OS focus. Its `is_process_focused()` is not reachable from a plugin,
##    but Godot grabs and releases the control's focus along with the process,
##    so the control's own `has_focus()` tracks the same state.
##  - The rest of the time it is the 3D viewport's own focus frame, drawn on the
##    pane's overlay when that overlay has focus.
##
## Both of those controls live under the pane, so `_pane_is_focused` checks them
## rather than assuming either one.
##
## The two outlines are joined into one continuous frame — see
## `_apply_pane_frame_override`.
func _create_toolbar_frame() -> void:
	if is_instance_valid(_toolbar_frame) or not is_instance_valid(_game_toolbar):
		return
	var base := EditorInterface.get_base_control()
	if base == null:
		return
	_toolbar_frame = Control.new()
	_toolbar_frame.name = "GameViewport3DFocusFrame"
	_toolbar_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toolbar_frame.visible = false
	_toolbar_frame.draw.connect(_on_toolbar_frame_draw)
	# Parented to the editor's base control, and positioned in global
	# coordinates, because it has to span two controls that are siblings rather
	# than nested. Neither of the obvious parents works: the strip is a
	# `MarginContainer` and pins any child to its own rect — `top_level` does
	# *not* exempt a child from that in 4.7 — and the pane sits inside
	# `Node3DEditorViewportContainer`, which clips, so a frame reaching above
	# the pane would be cut off in the layouts where the strip falls outside it.
	# The base control is a plain `Panel`: no layout, no clipping, and an
	# ancestor of both in every layout.
	base.add_child(_toolbar_frame)
	_toolbar_frame_lit = false
	_toolbar_frame_joined = false


func _destroy_toolbar_frame() -> void:
	_clear_pane_frame_override()
	if is_instance_valid(_toolbar_frame):
		_toolbar_frame.queue_free()
	_toolbar_frame = null
	_toolbar_frame_lit = false
	_toolbar_frame_joined = false


## The editor's focus style, optionally with its bottom edge opened up so the
## strip's outline runs into the pane's instead of closing above it.
##
## Resolved from the theme each time and rebuilt whenever the theme's own style
## changes, so it follows editor theme switches.
func _focus_box(open_bottom: bool) -> StyleBox:
	var theme := EditorInterface.get_editor_theme()
	if theme == null or not theme.has_stylebox(FOCUS_STYLEBOX, FOCUS_STYLEBOX_TYPE):
		return null
	var source := theme.get_stylebox(FOCUS_STYLEBOX, FOCUS_STYLEBOX_TYPE)
	if not open_bottom or not (source is StyleBoxFlat):
		return source
	if _frame_box_open_bottom == null or _frame_box_source != source:
		_frame_box_source = source
		_frame_box_open_bottom = (source as StyleBoxFlat).duplicate() as StyleBoxFlat
		_frame_box_open_bottom.border_width_bottom = 0
		# Square off the corners that now meet the pane, or the rounding would
		# pinch the outline in at the join.
		_frame_box_open_bottom.corner_radius_bottom_left = 0
		_frame_box_open_bottom.corner_radius_bottom_right = 0
		_frame_box_open_bottom.border_color = _flatten(_frame_box_open_bottom.border_color)
	return _frame_box_open_bottom


## Resolves the stock border colour to a flat one, by compositing it over the
## editor's own background exactly as the editor would.
##
## The stock border is the accent colour at half alpha, which does not survive a
## frame spanning two different backgrounds: the half over the dark toolbar
## renders much duller than the half over the viewport, and the dull stretch
## reads as a break in the outline. It would swing further still with a game
## running, since the colour behind that half is then whatever the game draws.
##
## Flattening it against `base_color` gives one colour end to end while keeping
## the muted tone the editor's own viewport frames have — using the accent
## colour at full opacity instead would join cleanly but come out far more
## vivid than every other viewport's frame.
func _flatten(color: Color) -> Color:
	if color.a >= 1.0:
		return color
	var background := Color(0.161, 0.161, 0.161)
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_color("base_color", "Editor"):
		background = theme.get_color("base_color", "Editor")
	return background.blend(color)


func _on_toolbar_frame_draw() -> void:
	var box := _focus_box(_toolbar_frame_joined)
	if box == null:
		return
	box.draw(_toolbar_frame.get_canvas_item(), Rect2(Vector2.ZERO, _toolbar_frame.size))


## Opens the *top* of the frame Godot draws around the pane, so it continues the
## strip's outline rather than closing under it.
##
## Godot resolves that style with `get_theme_stylebox("FocusViewport",
## "EditorStyles")`. A local `add_theme_stylebox_override` cannot reach it —
## overrides are only consulted when the requested theme type matches the
## control's own class — but theme *resolution* walks up the tree and takes the
## first owner that has the item, so giving the pane a `Theme` carrying just
## this one entry shadows it for the pane and everything under it. Everything
## else still falls through to the editor theme.
##
## Covering the pane's descendants is exactly right: the embedded game draws the
## same style from inside the pane, so both the playing and the not-playing
## frame get their top opened by this.
func _apply_pane_frame_override(pane: Control) -> void:
	var theme := EditorInterface.get_editor_theme()
	if theme == null or not theme.has_stylebox(FOCUS_STYLEBOX, FOCUS_STYLEBOX_TYPE):
		return
	var source := theme.get_stylebox(FOCUS_STYLEBOX, FOCUS_STYLEBOX_TYPE)
	if not (source is StyleBoxFlat):
		return
	if _pane_frame_target == pane and _pane_frame_source == source:
		return
	_clear_pane_frame_override()

	var open := (source as StyleBoxFlat).duplicate() as StyleBoxFlat
	open.border_width_top = 0
	open.corner_radius_top_left = 0
	open.corner_radius_top_right = 0
	open.border_color = _flatten(open.border_color)
	var shadow := Theme.new()
	shadow.set_stylebox(FOCUS_STYLEBOX, FOCUS_STYLEBOX_TYPE, open)

	_pane_frame_prev_theme = pane.theme
	pane.theme = shadow
	_pane_frame_target = pane
	_pane_frame_source = source


func _clear_pane_frame_override() -> void:
	if is_instance_valid(_pane_frame_target):
		_pane_frame_target.theme = _pane_frame_prev_theme
	_pane_frame_target = null
	_pane_frame_prev_theme = null
	_pane_frame_source = null


## The outlines can only be joined when the strip sits directly on top of the
## pane and spans exactly its width. In the fallback placements — a 1-viewport
## layout, or a 4-viewport row where the strip spans two panes — they do not
## line up, so each keeps its own closed outline.
func _frames_can_join(pane: Control) -> bool:
	return absf(_game_toolbar.global_position.x - pane.global_position.x) < 1.0 \
		and absf(_game_toolbar.size.x - pane.size.x) < 1.0 \
		and pane.global_position.y >= _game_toolbar.global_position.y + _game_toolbar.size.y - 1.0


## True whenever Godot is drawing its focus frame around the game's pane —
## around the running game while playing, around the 3D viewport otherwise.
##
## The embedded control's own `has_focus()` is not the test, even though that is
## what `EmbeddedProcess::is_process_focused()` reads. `EmbeddedProcessMacOS`
## has `focus_mode = FOCUS_NONE` and delegates to a `LayerHost` child, which is
## what actually holds focus while a game runs — so asking the control itself
## can only ever answer false, and the strip went dark the moment a game
## started. Its whole subtree is checked instead, which also covers the
## platforms where the embed control does take focus directly.
func _pane_is_focused() -> bool:
	var pane := _viewport_at(_applied_slot)
	if pane == null:
		return false
	var focus := pane.get_viewport().gui_get_focus_owner()
	if focus == null:
		return false
	if is_instance_valid(_embedded) and (focus == _embedded or _embedded.is_ancestor_of(focus)):
		return true
	# Not playing: the pane's overlay is what Godot's own frame keys on. Matched
	# exactly rather than by subtree, so focusing the pane's menu button does
	# not light a frame Godot is not drawing.
	var overlay := Internals.find_viewport_overlay(pane)
	return is_instance_valid(overlay) and focus == overlay


func _update_toolbar_frame() -> void:
	if not is_instance_valid(_toolbar_frame) or not is_instance_valid(_game_toolbar):
		return
	var pane := _viewport_at(_applied_slot)
	var joined := pane != null and _frames_can_join(pane)
	if joined:
		_apply_pane_frame_override(pane)
	else:
		_clear_pane_frame_override()

	var rect := Rect2(_game_toolbar.global_position, _game_toolbar.size)
	if joined:
		# Reach down to the pane's top edge, so the side borders carry straight
		# through the split's drag handle and the two outlines read as one.
		rect.size.y = pane.global_position.y - _game_toolbar.global_position.y

	var lit := _pane_is_focused()
	if lit:
		# Tracked every frame: the strip moves whenever the pane does.
		if not _toolbar_frame.global_position.is_equal_approx(rect.position) \
				or not _toolbar_frame.size.is_equal_approx(rect.size):
			_toolbar_frame.global_position = rect.position
			_toolbar_frame.size = rect.size
			_toolbar_frame.queue_redraw()
	if joined != _toolbar_frame_joined:
		_toolbar_frame_joined = joined
		_toolbar_frame.queue_redraw()
	if lit != _toolbar_frame_lit:
		_toolbar_frame_lit = lit
		_toolbar_frame.visible = lit
		_toolbar_frame.queue_redraw()


## Adds the plugin's own buttons to Godot's toolbar. Runs once per relocation,
## not per placement — the strip is re-parented whenever the viewport layout
## changes, and the buttons travel with it.
func _inject_toolbar_buttons() -> void:
	var row := Internals.find_toolbar_row(_game_toolbar)
	if is_instance_valid(row):
		_exit_button = Button.new()
		_exit_button.name = "GameViewport3DExit"
		_exit_button.flat = true
		_exit_button.tooltip_text = "Turn off Game View for this viewport"
		var theme := EditorInterface.get_editor_theme()
		if theme and theme.has_icon("Close", "EditorIcons"):
			_exit_button.icon = theme.get_icon("Close", "EditorIcons")
		else:
			_exit_button.text = "×"
		_exit_button.pressed.connect(_on_exit_pressed)
		row.add_child(_exit_button)
		row.move_child(_exit_button, 0)

	# Fullscreen sits immediately left of the trailing "⋮".
	var options := Internals.find_last_menu_button(_game_toolbar)
	if is_instance_valid(options) and options.get_parent() != null:
		_fullscreen_button = Button.new()
		_fullscreen_button.name = "GameViewport3DFullscreen"
		_fullscreen_button.flat = true
		_fullscreen_button.toggle_mode = true
		_fullscreen_button.button_pressed = _fullscreen
		_fullscreen_button.tooltip_text = "Expand the game to fill the 3D editor"
		var theme2 := EditorInterface.get_editor_theme()
		if theme2 and theme2.has_icon("DistractionFree", "EditorIcons"):
			_fullscreen_button.icon = theme2.get_icon("DistractionFree", "EditorIcons")
		else:
			_fullscreen_button.text = "Fullscreen"
		_fullscreen_button.toggled.connect(_on_fullscreen_toggled)
		var parent := options.get_parent()
		parent.add_child(_fullscreen_button)
		parent.move_child(_fullscreen_button, options.get_index())


func _restore_game_toolbar() -> void:
	_destroy_toolbar_frame()
	if is_instance_valid(_exit_button):
		_exit_button.queue_free()
	_exit_button = null
	if is_instance_valid(_fullscreen_button):
		_fullscreen_button.queue_free()
	_fullscreen_button = null

	if not _toolbar_relocated:
		return
	_toolbar_relocated = false
	if not is_instance_valid(_game_toolbar) or not is_instance_valid(_toolbar_origin_parent):
		return
	_game_toolbar.custom_maximum_size = _toolbar_origin_max_size
	if _game_toolbar.get_parent() != null:
		_game_toolbar.get_parent().remove_child(_game_toolbar)
	_release_toolbar_split()
	_toolbar_origin_parent.add_child(_game_toolbar)
	_toolbar_origin_parent.move_child(_game_toolbar, clampi(_toolbar_origin_index, 0, _toolbar_origin_parent.get_child_count() - 1))
	_game_toolbar.show()


func _on_exit_pressed() -> void:
	_set_enabled(false)


## Expands the game pane to fill the whole 3D editor area by collapsing every
## sibling on the way up to the viewport container.
##
## The panes live in nested `SplitContainer`s, and a container gives its space
## to the children that remain visible — so hiding the siblings makes this pane
## full size using Godot's own layout. Nothing is reparented, which matters:
## detaching the host would tear down a live embedding.
func _apply_fullscreen() -> void:
	_clear_fullscreen()
	if not _relocated:
		return

	_fullscreen_splits.clear()

	# Every `SplitContainer` on the way up has its proportions recorded first,
	# in a pass of its own, and *before anything at all is hidden* — including
	# by distraction-free mode below. A split re-clamps its offsets against
	# whatever is still visible, so the moment something is hidden the original
	# proportions are gone, and showing the siblings again does not bring them
	# back. Recording after distraction-free mode had already hidden the docks
	# captured a short array — one offset for a split that needs two — and
	# writing that back left the Inspector at the wrong width.
	var scan: Node = _viewport_at(_applied_slot)
	while scan != null and scan != EditorInterface.get_base_control():
		var split := scan.get_parent()
		if split == null:
			break
		if split is SplitContainer and split.has_method("get_split_offsets"):
			_fullscreen_splits.append([split, split.get_split_offsets().duplicate()])
		scan = split

	_fullscreen_prev_distraction = EditorInterface.is_distraction_free_mode_enabled()
	EditorInterface.set_distraction_free_mode(true)

	# Walk from the game pane all the way to the editor root, hiding every
	# visible sibling on the way: the other viewport panes, the 3D toolbar,
	# the scene tabs, the docks and the title bar. Containers hand their space
	# to whatever remains visible, so the pane expands to the whole window
	# through Godot's own layout — nothing is reparented, which matters because
	# detaching the host would tear down a live embedding.
	#
	# The Game toolbar is deliberately exempt. The embedded game composites
	# over everything in its rect, so once it fills the window no editor
	# control inside it can be clicked — that strip is the only way back out.
	var keep: Node = _game_toolbar if (_show_game_toolbar and _toolbar_relocated) else null
	var root: Node = EditorInterface.get_base_control()
	var node: Node = _viewport_at(_applied_slot)
	while node != null and node != root:
		var parent := node.get_parent()
		if parent == null:
			break
		for sibling in parent.get_children(true):
			if sibling == node or not (sibling is Control):
				continue
			if keep != null and (sibling == keep or sibling.is_ancestor_of(keep)):
				continue
			var control := sibling as Control
			if control.visible:
				control.hide()
				_fullscreen_hidden.append(control)
		node = parent

	_fullscreen_prev_window_mode = DisplayServer.window_get_mode()
	if _fullscreen_prev_window_mode != DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


func _clear_fullscreen() -> void:
	for control in _fullscreen_hidden:
		if is_instance_valid(control):
			control.show()
	_fullscreen_hidden.clear()

	if _fullscreen_prev_window_mode >= 0:
		if DisplayServer.window_get_mode() != _fullscreen_prev_window_mode:
			DisplayServer.window_set_mode(_fullscreen_prev_window_mode)
		EditorInterface.set_distraction_free_mode(_fullscreen_prev_distraction)
		_fullscreen_prev_window_mode = -1

	if not _fullscreen_splits.is_empty():
		_queue_split_restore(_fullscreen_splits)
		_fullscreen_splits.clear()


## Hands proportions to the re-assert loop and applies them immediately.
##
## One application is not enough. Leaving fullscreen resizes the window
## asynchronously, and adding or removing a child makes the split re-clamp on
## its next sort — either way the offsets are recomputed again after the call,
## so they are re-asserted over the following frames until the layout settles.
func _queue_split_restore(entries: Array) -> void:
	for entry in entries:
		_split_restore.append(entry)
	_restore_split_offsets()
	_split_restore_frames = SPLIT_RESTORE_FRAMES


## Puts back the split proportions recorded before a change. Skips
## splits already at the recorded value, so re-asserting costs nothing and
## never triggers a needless resort.
##
## A split reports one offset per gap between its *visible* children, so the
## array is only meaningful against the same set of visible children it was
## recorded with. On a length mismatch the split is left alone: writing a short
## array leaves the trailing draggers wherever they happen to sit, which is what
## resized the Inspector. Doing nothing restores nothing; writing the wrong
## thing actively breaks the layout.
func _restore_split_offsets() -> void:
	for entry in _split_restore:
		var split: SplitContainer = entry[0]
		if not is_instance_valid(split):
			continue
		var current: Variant = split.get_split_offsets()
		if current.size() != entry[1].size():
			continue
		# Compared as plain arrays: the two sides can be a `PackedInt32Array` and
		# an `Array`, which never compare equal to each other directly.
		if Array(current) != Array(entry[1]):
			split.set_split_offsets(entry[1])
			split.queue_sort()


func _on_fullscreen_toggled(pressed: bool) -> void:
	_fullscreen = pressed
	if pressed:
		_apply_fullscreen()
	else:
		_clear_fullscreen()


## Root to search for the Game view's menus.
##
## Once Game View is on, the toolbar that owns these menus lives in the strip
## above the game's pane, so searching under `GameView` finds nothing. Search
## the toolbar itself, wherever it currently lives.
func _menus_root() -> Node:
	if is_instance_valid(_game_toolbar):
		return _game_toolbar
	return _game_view


## Selects "Stretch to Fit" in the Game view's Game Window Options menu.
##
## `EmbeddedProcess` exposes no sizing API to scripting, so this drives Godot's
## own menu instead: the item is found by label and its `id_pressed` is emitted,
## which runs the very handler a click would.
func _apply_stretch_to_fit() -> void:
	if not _stretch_to_fit:
		return
	var root := _menus_root()
	if not is_instance_valid(root):
		return
	for node in Internals.find_all(root, func(n: Node) -> bool: return n is PopupMenu):
		var menu := node as PopupMenu
		for i in menu.item_count:
			if menu.get_item_text(i) != STRETCH_ITEM_TEXT:
				continue
			if not menu.is_item_checked(i):
				menu.id_pressed.emit(menu.get_item_id(i))
			return


# --- Viewport view-menu integration ---------------------------------------


## Puts a "Game Window" toggle beside every pane's "⋮ Perspective" menu.
##
## Every pane offers one while none is chosen, so picking the game's pane is a
## single click on the pane itself rather than a hunt through a dropdown. Once
## one is on, the others hide — the toggle then reads as a label naming the pane
## the game lives in, and there is only ever one on screen.
##
## They share the menu button's `HBoxContainer`, so the row supplies the spacing
## and the editor styles them like the pane's own chrome. The row lives in the
## pane's overlay, which is hidden while a game runs; the toolbar's × is the way
## back out then, exactly as before.
func _install_pane_toggles() -> void:
	for index in _viewports.size():
		if _pane_toggles.has(index) and is_instance_valid(_pane_toggles[index]):
			continue
		var pane := _viewport_at(index)
		if pane == null:
			continue
		var menu_button := Internals.find_view_menu_button(pane)
		if menu_button == null or menu_button.get_parent() == null:
			continue
		# A CheckBox rather than a plain toggle button: it draws the tick and
		# reserves its area whether ticked or not, so the control reads as
		# something you switch rather than something you press.
		var toggle := CheckBox.new()
		toggle.name = "GameViewport3DToggle"
		toggle.text = PANE_TOGGLE_TEXT
		toggle.tooltip_text = "Show the running game in this viewport"
		# Never take focus: the focus frame keys on the pane's overlay, and a
		# button stealing focus would darken the frame it just turned on.
		toggle.focus_mode = Control.FOCUS_NONE
		toggle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_match_menu_button_style(toggle, menu_button)
		toggle.toggled.connect(_on_pane_toggled.bind(index))
		var row := menu_button.get_parent()
		row.add_child(toggle)
		row.move_child(toggle, mini(menu_button.get_index() + 1, row.get_child_count() - 1))
		_pane_toggles[index] = toggle
	_update_pane_toggles()


## Remembers the host split's proportions from before the strip joins it.
##
## Adding the strip gives the split another child, and it redistributes to make
## room; removing it again does not undo that, so the panes came back at
## different sizes than they went in. The proportions are captured here and put
## back by `_release_toolbar_split` once the strip has left.
func _capture_toolbar_split(split: Node) -> void:
	_toolbar_split = split as SplitContainer
	_toolbar_split_offsets = []
	if _toolbar_split != null and _toolbar_split.has_method("get_split_offsets"):
		_toolbar_split_offsets = _toolbar_split.get_split_offsets().duplicate()


## Keeps the panes' proportions when the strip joins the split.
##
## Offsets are per dragger and each is measured from that dragger's own default
## position, so inserting the strip — which adds a dragger — shifts every later
## offset onto the wrong boundary. Left alone, the offset that used to separate
## the panes landed between the strip and the first pane and squashed it flat:
## enabling Game View on the top pane collapsed it to its minimum.
##
## The strip splits one old boundary into two, so both new draggers take that
## boundary's offset. Giving it to only the leading one stretches the strip's
## slot instead, and since the strip is pinned to its natural height that space
## is simply lost — the panes came back short by the offset's whole value.
## Inserted at the front there is no boundary to carry over, so a zero goes in
## and the rest shift along.
##
## Skipped unless exactly one dragger appeared, which is also what tells us the
## indices line up — with a hidden child in the split they would not.
func _seat_toolbar_offsets(split: SplitContainer) -> void:
	if not split.has_method("get_split_offsets") or Array(_toolbar_split_offsets).is_empty():
		return
	var seated: Array = Array(_toolbar_split_offsets)
	if Array(split.get_split_offsets()).size() != seated.size() + 1:
		return
	var index := clampi(_game_toolbar.get_index(), 0, seated.size())
	seated.insert(index, seated[index - 1] if index > 0 else 0)
	split.set_split_offsets(seated)
	split.queue_sort()


## Puts the host split back the way it was. Call *after* the strip has been
## removed: the offsets only mean what they meant originally once the split is
## back to the same set of visible children.
func _release_toolbar_split() -> void:
	if is_instance_valid(_toolbar_split) and not _toolbar_split_offsets.is_empty():
		_queue_split_restore([[_toolbar_split, _toolbar_split_offsets]])
	_toolbar_split = null
	_toolbar_split_offsets = []


## Gives the toggle the same panel the "⋮ Perspective" button sits on, by
## copying that button's own resolved styles rather than guessing at them — so
## it tracks whatever editor theme is in use.
##
## The pane's menu button resolves every state to one translucent rounded box,
## which a default `CheckBox` does not: it would come out opaque, squarer in its
## padding and visibly foreign next to its neighbour. Any state the menu button
## does not define falls back to its `normal`, so no state is left looking
## different from the rest.
func _match_menu_button_style(toggle: Control, menu_button: Control) -> void:
	if not menu_button.has_theme_stylebox("normal"):
		return
	var fallback := menu_button.get_theme_stylebox("normal")
	for state in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		var box := menu_button.get_theme_stylebox(state) if menu_button.has_theme_stylebox(state) else fallback
		toggle.add_theme_stylebox_override(state, box)


func _uninstall_pane_toggles() -> void:
	for toggle in _pane_toggles.values():
		if is_instance_valid(toggle):
			toggle.queue_free()
	_pane_toggles.clear()


func _update_pane_toggles() -> void:
	var chosen := _applied_slot if _relocated else _slot
	for index in _pane_toggles:
		var toggle: Button = _pane_toggles[index]
		if not is_instance_valid(toggle):
			continue
		var active: bool = _want_relocated and chosen == index
		toggle.visible = active or not _want_relocated
		toggle.set_pressed_no_signal(active)


func _on_pane_toggled(pressed: bool, index: int) -> void:
	if pressed:
		# The moment of clearest intent: if embedding cannot work with the
		# current editor settings, offer the fix right here.
		_show_prereq_dialog()
	if pressed:
		_set_slot(index)
		_set_enabled(true)
	else:
		_set_enabled(false)
	_update_pane_toggles()


# --- Game tab notice -------------------------------------------------------


func _show_notice() -> void:
	if is_instance_valid(_notice) or not is_instance_valid(_game_view):
		return
	_notice = Label.new()
	_notice.name = "GameViewport3DNotice"
	_notice.text = "Game Viewport 3D: the game and its toolbar are displayed in the 3D editor viewport."
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_game_view.add_child(_notice)


func _hide_notice() -> void:
	if is_instance_valid(_notice):
		_notice.queue_free()
	_notice = null


# --- Node resolution -------------------------------------------------------


func _connect_embed_signals() -> void:
	if not is_instance_valid(_embedded):
		return
	if _embedded.has_signal("embedding_completed") and not _embedded.embedding_completed.is_connected(_on_embedding_completed):
		_embedded.embedding_completed.connect(_on_embedding_completed)
	if _embedded.has_signal("embedding_failed") and not _embedded.embedding_failed.is_connected(_on_embedding_failed):
		_embedded.embedding_failed.connect(_on_embedding_failed)
	if _embedded.has_signal("embedded_process_focused") and not _embedded.embedded_process_focused.is_connected(_on_embedded_process_focused):
		_embedded.embedded_process_focused.connect(_on_embedded_process_focused)


func _disconnect_embed_signals() -> void:
	if not is_instance_valid(_embedded):
		return
	if _embedded.has_signal("embedding_completed") and _embedded.embedding_completed.is_connected(_on_embedding_completed):
		_embedded.embedding_completed.disconnect(_on_embedding_completed)
	if _embedded.has_signal("embedding_failed") and _embedded.embedding_failed.is_connected(_on_embedding_failed):
		_embedded.embedding_failed.disconnect(_on_embedding_failed)
	if _embedded.has_signal("embedded_process_focused") and _embedded.embedded_process_focused.is_connected(_on_embedded_process_focused):
		_embedded.embedded_process_focused.disconnect(_on_embedded_process_focused)


func _resolve_nodes() -> bool:
	if is_instance_valid(_embedded) and not _viewports.is_empty() and is_instance_valid(_viewports[0]):
		return true

	# Searching means walking the whole editor tree, so back off between
	# attempts rather than paying for it on every idle frame.
	_resolve_cooldown -= 1
	if _resolve_cooldown > 0:
		return false
	_resolve_cooldown = RESOLVE_RETRY_FRAMES

	var base := EditorInterface.get_base_control()
	if base == null:
		return false

	if not is_instance_valid(_viewport_container):
		_viewport_container = Internals.find_viewport_container(base)
	if _viewports.is_empty() or not is_instance_valid(_viewports[0]):
		_viewports = Internals.get_editor_viewports(_viewport_container)
		if not _viewports.is_empty():
			_install_pane_toggles()
	if not is_instance_valid(_game_view):
		_game_view = Internals.find_game_view(base)
		if is_instance_valid(_game_view) and not _game_view.visibility_changed.is_connected(_on_game_view_visibility_changed):
			_game_view.visibility_changed.connect(_on_game_view_visibility_changed)
	if not is_instance_valid(_embedded):
		_embedded = Internals.find_embedded_process(base)
		_connect_embed_signals()

	if not is_instance_valid(_embedded):
		_set_status("Game embedding unavailable in this build")
		return false
	if _viewports.is_empty():
		_set_status("3D editor viewports not found")
		return false
	return true


func _set_status(text: String) -> void:
	if text.is_empty() or text == _last_status:
		return
	_last_status = text
	push_warning("Game Viewport 3D: " + text)


# --- Settings --------------------------------------------------------------


func _define_settings() -> void:
	_define("enabled", false)
	_define("target_slot", 1, {
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Viewport 1,Viewport 2,Viewport 3,Viewport 4",
	})
	_define("switch_to_3d_on_play", true)
	_define("stretch_to_fit", true)
	_define("show_game_toolbar", true)
	_define("keep_3d_on_game_focus", true)
	_define("hide_game_tab", true)
	_define("fullscreen_on_play", false)


func _define(key: String, value: Variant, info: Dictionary = {}) -> void:
	var settings := EditorInterface.get_editor_settings()
	var full := SETTING_PREFIX + key
	if not settings.has_setting(full):
		settings.set_setting(full, value)
	settings.set_initial_value(full, value, false)
	if not info.is_empty():
		var property := info.duplicate()
		property["name"] = full
		settings.add_property_info(property)


## Raw editor-settings read (no plugin prefix), with a fallback for settings
## that do not exist in a given build.
func _get_editor_setting(name: String, fallback: Variant) -> Variant:
	var settings := EditorInterface.get_editor_settings()
	return settings.get_setting(name) if settings.has_setting(name) else fallback


## The editor settings embedding needs, as human-readable fixes. Embed mode 0
## ("Use Per-Project Configuration") is deliberately not flagged: that project
## may well configure embedding correctly, and second-guessing it would nag
## setups that already work.
func _prerequisites_missing() -> PackedStringArray:
	var missing: PackedStringArray = []
	var embed_mode := int(_get_editor_setting(SETTING_EMBED_MODE, EMBED_MODE_EMBED))
	if embed_mode < 0 or embed_mode == 2:
		missing.append("•  Run → Window Placement → Game Embed Mode: \"Embed Game\"")
	if bool(_get_editor_setting(SETTING_SINGLE_WINDOW, false)):
		missing.append("•  Interface → Editor → Display → Single Window Mode: off")
	if not bool(_get_editor_setting(SETTING_MULTI_WINDOW, true)):
		missing.append("•  Interface → Multi Window → Enable: on")
	return missing


## Single-window and multi-window changes only take effect after an editor
## restart; the embed mode applies on the next Play.
func _prereq_needs_restart() -> bool:
	return bool(_get_editor_setting(SETTING_SINGLE_WINDOW, false)) \
		or not bool(_get_editor_setting(SETTING_MULTI_WINDOW, true))


## Applies only the settings that are actually wrong. Never called without the
## user confirming the dialog — these are user-global editor settings, and
## changing them silently is not this plugin's call to make.
func _apply_prerequisites() -> void:
	var settings := EditorInterface.get_editor_settings()
	var embed_mode := int(_get_editor_setting(SETTING_EMBED_MODE, EMBED_MODE_EMBED))
	if embed_mode < 0 or embed_mode == 2:
		settings.set_setting(SETTING_EMBED_MODE, EMBED_MODE_EMBED)
	if bool(_get_editor_setting(SETTING_SINGLE_WINDOW, false)):
		settings.set_setting(SETTING_SINGLE_WINDOW, false)
	if not bool(_get_editor_setting(SETTING_MULTI_WINDOW, true)):
		settings.set_setting(SETTING_MULTI_WINDOW, true)


func _on_prereq_confirmed() -> void:
	var restart := _prereq_needs_restart()
	_apply_prerequisites()
	# The dialog is torn down completely before the restart, and the restart is
	# deferred a frame. Restarting synchronously from inside this handler left
	# our dialog mid-teardown when the quit sequence raised the editor's own
	# prompts ("save scripts?"), and the clash of modals wedged their input.
	if is_instance_valid(_prereq_dialog):
		_prereq_dialog.queue_free()
		_prereq_dialog = null
	if restart:
		EditorInterface.restart_editor.call_deferred(true)


func _show_prereq_dialog() -> void:
	if is_instance_valid(_prereq_dialog):
		return
	var missing := _prerequisites_missing()
	if missing.is_empty():
		return
	var needs_restart := _prereq_needs_restart()
	_prereq_dialog = ConfirmationDialog.new()
	_prereq_dialog.title = "Game Viewport 3D"
	_prereq_dialog.dialog_text = "Game embedding needs these editor settings changed:\n\n" \
		+ "\n".join(missing) \
		+ ("\n\nThe editor must restart for them to take effect." if needs_restart else "")
	_prereq_dialog.ok_button_text = "Apply and Restart Editor" if needs_restart else "Apply"
	_prereq_dialog.cancel_button_text = "Not Now"
	# Never exclusive: an exclusive dialog can block input to any prompt the
	# editor raises after it, and nothing here needs modality anyway.
	_prereq_dialog.exclusive = false
	_prereq_dialog.confirmed.connect(_on_prereq_confirmed)
	var base := EditorInterface.get_base_control()
	if base == null:
		_prereq_dialog = null
		return
	base.add_child(_prereq_dialog)
	# Headless runs have no windowing to pop into.
	if DisplayServer.get_name() != "headless":
		_prereq_dialog.popup_centered()


func _get_setting(key: String, fallback: Variant) -> Variant:
	var settings := EditorInterface.get_editor_settings()
	var full := SETTING_PREFIX + key
	return settings.get_setting(full) if settings.has_setting(full) else fallback


func _load_settings() -> void:
	_want_relocated = bool(_get_setting("enabled", false))
	_slot = clampi(int(_get_setting("target_slot", 1)), 0, 3)
	_switch_to_3d = bool(_get_setting("switch_to_3d_on_play", true))
	_keep_3d_on_game_focus = bool(_get_setting("keep_3d_on_game_focus", true))
	_fullscreen_on_play = bool(_get_setting("fullscreen_on_play", false))

	var was_hiding_tab := _hide_game_tab
	_hide_game_tab = bool(_get_setting("hide_game_tab", true))
	if _hide_game_tab != was_hiding_tab:
		# Turned off, the tab has to come back right away rather than at the
		# next _restore(); turned on, clear a failed lookup so it is retried.
		if _hide_game_tab:
			_game_tab_lookup_failed = false
		else:
			_show_game_main_screen()

	var was_stretch := _stretch_to_fit
	_stretch_to_fit = bool(_get_setting("stretch_to_fit", true))
	if _stretch_to_fit and not was_stretch and _relocated:
		_apply_stretch_to_fit()

	var was_showing_toolbar := _show_game_toolbar
	_show_game_toolbar = bool(_get_setting("show_game_toolbar", true))
	if _relocated and _show_game_toolbar != was_showing_toolbar:
		if _show_game_toolbar:
			_relocate_game_toolbar()
		else:
			_restore_game_toolbar()

	_update_pane_toggles()


func _set_enabled(value: bool) -> void:
	_want_relocated = value
	EditorInterface.get_editor_settings().set_setting(SETTING_PREFIX + "enabled", value)


func _set_slot(value: int) -> void:
	_slot = value
	EditorInterface.get_editor_settings().set_setting(SETTING_PREFIX + "target_slot", value)
