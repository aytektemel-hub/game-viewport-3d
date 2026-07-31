@tool
extends RefCounted

## Helpers for locating undocumented editor-internal nodes.
##
## Godot does not expose the 3D editor's viewport container or the Game view's
## embedded-process control to scripting, but every Node still reports its real
## native class through `get_class()`. We locate nodes by class name and only
## ever call generic `Node`/`Control` API on the results, so nothing here
## depends on unexposed methods.

const EMBED_CLASS_PREFIX := "EmbeddedProcess"
const VIEWPORT_CONTAINER_CLASS := "Node3DEditorViewportContainer"
const VIEWPORT_CLASS := "Node3DEditorViewport"
const GAME_VIEW_CLASS := "GameView"


static func _walk(node: Node, matcher: Callable, out: Array, limit: int) -> void:
	# `true` includes internal children; large parts of the editor UI are built
	# with them and would otherwise be invisible to this search.
	for child in node.get_children(true):
		if matcher.call(child):
			out.append(child)
			if limit > 0 and out.size() >= limit:
				return
		_walk(child, matcher, out, limit)
		if limit > 0 and out.size() >= limit:
			return


static func find_all(root: Node, matcher: Callable, limit: int = 0) -> Array:
	var out: Array = []
	if is_instance_valid(root):
		_walk(root, matcher, out, limit)
	return out


static func find_first(root: Node, matcher: Callable) -> Node:
	var found := find_all(root, matcher, 1)
	return found[0] if not found.is_empty() else null


## The Game view's embedded-process control. On macOS this is
## `EmbeddedProcessMacOS`, elsewhere `EmbeddedProcess` — both share the prefix.
static func find_embedded_process(base: Node) -> Control:
	var node := find_first(base, func(n: Node) -> bool:
		return n is Control and n.get_class().begins_with(EMBED_CLASS_PREFIX))
	return node as Control


static func find_viewport_container(base: Node) -> Control:
	var node := find_first(base, func(n: Node) -> bool:
		return n.get_class() == VIEWPORT_CONTAINER_CLASS)
	return node as Control


## The Game view's toolbar — the sizing, scale, camera-override and audio
## controls. It is the `MarginContainer` wrapping the toolbar's HBoxes, and is
## the first direct child of `GameView`.
static func find_game_toolbar(game_view: Node) -> Control:
	if not is_instance_valid(game_view):
		return null
	for child in game_view.get_children(true):
		if child.get_class() == "MarginContainer" and child is Control:
			return child as Control
	return null


static func find_game_view(base: Node) -> Control:
	var node := find_first(base, func(n: Node) -> bool:
		return n.get_class() == GAME_VIEW_CLASS)
	return node as Control


## The four `Node3DEditorViewport` panes, in layout order.
##
## As of Godot 4.7 these are not direct children of the container — they are
## nested inside a tree of `SplitContainer`s — so the search is recursive.
## Depth-first order matches the editor's own viewport numbering.
static func get_editor_viewports(container: Node) -> Array[Control]:
	var out: Array[Control] = []
	for node in find_all(container, func(n: Node) -> bool:
			return n.get_class() == VIEWPORT_CLASS and n is Control):
		out.append(node as Control)
	return out


## The container holding the pane's 3D render. Hiding it blanks the 3D scene
## without disturbing the editor's viewport layout.
static func find_viewport_render(editor_viewport: Node) -> Control:
	for child in editor_viewport.get_children(true):
		if child.get_class() == "SubViewportContainer" and child is Control:
			return child as Control
	return null


## The pane's overlay layer: the view menu, the info readout, the rotation
## gizmo and the navigation pads. It is the direct child whose class is exactly
## `Control`.
static func find_viewport_overlay(editor_viewport: Node) -> Control:
	for child in editor_viewport.get_children(true):
		if child.get_class() == "Control" and child is Control:
			return child as Control
	return null


## The pane's "⋮ Perspective" button. It is the first `MenuButton` in the pane,
## and sits in an `HBoxContainer` at the top-left of the pane's overlay.
static func find_view_menu_button(editor_viewport: Node) -> MenuButton:
	return find_first(editor_viewport, func(n: Node) -> bool: return n is MenuButton) as MenuButton



## A main-screen selector button ("2D", "3D", "Script", "Game", "Asset Store").
##
## Matched by requiring its sibling row to hold the other main-screen buttons,
## because the Game view's own toolbar also contains buttons labelled "2D" and
## "3D" that must not be confused for these.
static func find_main_screen_button(base: Node, label: String) -> Button:
	for node in find_all(base, func(n: Node) -> bool:
			return n is Button and (n as Button).text == label):
		var row: Node = (node as Node).get_parent()
		if row == null:
			continue
		var labels := {}
		for sibling in row.get_children(true):
			if sibling is Button:
				labels[(sibling as Button).text] = true
		if labels.has("2D") and labels.has("3D") and labels.has("Script"):
			return node as Button
	return null


## The trailing "⋮" of the Game view toolbar — the Game Window Options button.
## It is the last `MenuButton` in the toolbar, and new buttons are inserted
## before it so they land to its left.
static func find_last_menu_button(game_toolbar: Node) -> MenuButton:
	var buttons := find_all(game_toolbar, func(n: Node) -> bool: return n is MenuButton)
	if buttons.is_empty():
		return null
	return buttons[buttons.size() - 1] as MenuButton


## The HBox inside the Game view toolbar, where extra buttons can be inserted.
static func find_toolbar_row(game_toolbar: Node) -> Control:
	var node := find_first(game_toolbar, func(n: Node) -> bool: return n is HBoxContainer)
	return node as Control
