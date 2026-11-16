extends Node2D
## Tilt prototype: gray-box board, swipe/arrow input, undo, restart, hints, stars.

const Rules := preload("res://scripts/tilt_rules.gd")

const LEVELS_PATH := "res://levels/levels.json"
const SWIPE_MIN_PX := 40.0
const SECONDS_PER_CELL := 0.06
const FREE_HINTS := 3

const BG_COLOR := Color("#2b2d42")
const FLOOR_COLOR := Color("#8d99ae")
const WALL_COLOR := Color("#4a4e69")
const MARBLE_COLORS := {
	"r": Color("#e63946"),
	"g": Color("#2a9d8f"),
	"b": Color("#457b9d"),
	"y": Color("#f4a261"),
	"p": Color("#9b5de5"),
}

var levels: Array = []
var level_index := 0
var lvl: Dictionary = {}
var marbles: Array = []
var holes: Dictionary = {}
var history: Array = []
var moves := 0
var won := false
var hints_left := FREE_HINTS

# Animation state
var animating := false
var anim_t := 0.0
var anim_marbles: Array = []
var anim_max_dist := 0.0
var anim_dir := Vector2i.ZERO

# Layout
var cell := 64.0
var origin := Vector2.ZERO

# Input
var _touch_start := Vector2.ZERO
var _touching := false

# UI
var title_label: Label
var status_label: Label
var hint_button: Button
var next_button: Button


func _ready() -> void:
	_load_levels()
	_build_ui()
	get_viewport().size_changed.connect(_layout)
	_start_level(0)


func _load_levels() -> void:
	var text := FileAccess.get_file_as_string(LEVELS_PATH)
	var data = JSON.parse_string(text)
	if data == null or not data.has("levels"):
		push_error("Could not read " + LEVELS_PATH)
		return
	levels = data["levels"]


func _start_level(index: int) -> void:
	if levels.is_empty():
		return
	level_index = clampi(index, 0, levels.size() - 1)
	lvl = Rules.parse(levels[level_index]["rows"])
	marbles = lvl["marbles"].duplicate(true)
	holes = lvl["holes"].duplicate()
	history.clear()
	moves = 0
	won = false
	animating = false
	_layout()
	_update_ui("Swipe to tilt the board.")


func _layout() -> void:
	if lvl.is_empty():
		return
	var vp := get_viewport_rect().size
	var top := 180.0
	var bottom := 220.0
	var avail := Vector2(vp.x - 40.0, vp.y - top - bottom)
	cell = floorf(min(avail.x / lvl["w"], avail.y / lvl["h"]))
	var board := Vector2(lvl["w"], lvl["h"]) * cell
	origin = Vector2((vp.x - board.x) / 2.0, top + (avail.y - board.y) / 2.0)
	queue_redraw()


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_start = event.position
			_touching = true
		elif _touching:
			_touching = false
			var delta: Vector2 = event.position - _touch_start
			if delta.length() >= SWIPE_MIN_PX:
				if absf(delta.x) > absf(delta.y):
					_try_move("R" if delta.x > 0 else "L")
				else:
					_try_move("D" if delta.y > 0 else "U")
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_UP, KEY_W: _try_move("U")
			KEY_DOWN, KEY_S: _try_move("D")
			KEY_LEFT, KEY_A: _try_move("L")
			KEY_RIGHT, KEY_D: _try_move("R")
			KEY_Z: _on_undo()
			KEY_R: _on_restart()
			KEY_H: _on_hint()
			KEY_N: _on_next()
			KEY_P: _start_level(level_index - 1)


# ---------------------------------------------------------------- moves

func _try_move(dir: String) -> void:
	if animating or won or lvl.is_empty():
		return
	var r := Rules.slide(lvl["w"], lvl["h"], lvl["walls"], marbles, holes, dir)
	var moved := false
	anim_max_dist = 0.0
	for m in r["marbles"]:
		var dist := Vector2(m["pos"] - m["from"]).length()
		if dist > 0.0:
			moved = true
		anim_max_dist = maxf(anim_max_dist, dist)
	if not moved:
		return
	history.append({"marbles": marbles.duplicate(true), "holes": holes.duplicate()})
	moves += 1
	anim_marbles = r["marbles"]
	anim_dir = Rules.DIRS[dir]
	marbles = []
	for m in r["marbles"]:
		if not m["dropped"]:
			marbles.append({"pos": m["pos"], "color": m["color"]})
	holes = r["holes"]
	animating = true
	anim_t = 0.0
	var tween := create_tween()
	tween.tween_property(self, "anim_t", 1.0, SECONDS_PER_CELL * anim_max_dist + 0.04)
	tween.finished.connect(_on_move_finished)
	_update_ui("")


func _on_move_finished() -> void:
	animating = false
	queue_redraw()
	if marbles.is_empty():
		won = true
		var par: int = levels[level_index]["par"]
		var stars := 3 if moves <= par else (2 if moves <= par + 3 else 1)
		_update_ui("Solved in %d moves (par %d)  -  Stars: %d/3" % [moves, par, stars])


func _on_undo() -> void:
	if animating or history.is_empty():
		return
	var last: Dictionary = history.pop_back()
	marbles = last["marbles"]
	holes = last["holes"]
	moves -= 1
	won = false
	queue_redraw()
	_update_ui("")


func _on_restart() -> void:
	if not animating:
		_start_level(level_index)


func _on_hint() -> void:
	if animating or won:
		return
	if hints_left > 0:
		hints_left -= 1
		_show_hint()
	else:
		Ads.show_rewarded(func():
			hints_left += 1
			_update_ui("You earned a hint. Tap Hint to use it."))


func _show_hint() -> void:
	var path := Rules.solve(lvl["w"], lvl["h"], lvl["walls"], marbles, holes)
	if path.is_empty():
		_update_ui("No solution from here. Try Undo or Restart.")
		return
	var names := {"U": "UP", "D": "DOWN", "L": "LEFT", "R": "RIGHT"}
	_update_ui("Hint: swipe %s  (%d moves left at best)" % [names[path[0]], path.size()])


func _on_next() -> void:
	if animating:
		return
	var finished_level := level_index + 1
	var go_next := func(): _start_level((level_index + 1) % levels.size())
	if won:
		Ads.on_level_complete(finished_level, go_next)
	else:
		go_next.call()  # prototype: allow skipping while testing


# ---------------------------------------------------------------- drawing

func _process(_delta: float) -> void:
	if animating:
		queue_redraw()


func _cell_center(p: Vector2) -> Vector2:
	return origin + (p + Vector2(0.5, 0.5)) * cell


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), BG_COLOR)
	if lvl.is_empty():
		return
	for y in lvl["h"]:
		for x in lvl["w"]:
			var rect := Rect2(origin + Vector2(x, y) * cell, Vector2(cell, cell)).grow(-2.0)
			draw_rect(rect, WALL_COLOR if lvl["walls"].has(Vector2i(x, y)) else FLOOR_COLOR)

	# Holes: open = colored ring; filled = solid dim circle.
	# While a marble is still rolling toward its hole, keep that hole drawn open.
	var open_now := holes.duplicate()
	if animating:
		for m in anim_marbles:
			if m["dropped"]:
				open_now[m["pos"]] = m["color"]
	for p in lvl["holes"]:
		var col: Color = MARBLE_COLORS.get(lvl["holes"][p], Color.WHITE)
		var c := _cell_center(Vector2(p))
		if open_now.has(p):
			draw_circle(c, cell * 0.32, Color(0, 0, 0, 0.35))
			draw_arc(c, cell * 0.30, 0.0, TAU, 40, col, maxf(3.0, cell * 0.08))
		else:
			draw_circle(c, cell * 0.30, col.darkened(0.45))

	if animating:
		for m in anim_marbles:
			var from := Vector2(m["from"])
			var dist := Vector2(m["pos"] - m["from"]).length()
			var travelled := minf(dist, anim_t * anim_max_dist)
			var pos := from + Vector2(anim_dir) * travelled
			var size_scale := 1.0
			if m["dropped"] and travelled >= dist:
				size_scale = 0.6
			_draw_marble(_cell_center(pos), m["color"], size_scale)
	else:
		for m in marbles:
			_draw_marble(_cell_center(Vector2(m["pos"])), m["color"], 1.0)


func _draw_marble(c: Vector2, color_key: String, size_scale: float) -> void:
	var col: Color = MARBLE_COLORS.get(color_key, Color.WHITE)
	var r := cell * 0.36 * size_scale
	draw_circle(c + Vector2(0, r * 0.12), r, Color(0, 0, 0, 0.3))
	draw_circle(c, r, col)
	draw_circle(c + Vector2(-r * 0.35, -r * 0.35), r * 0.28, Color(1, 1, 1, 0.45))


# ---------------------------------------------------------------- UI

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(root)

	title_label = _make_label(root, 44, 40.0, 100.0)
	status_label = _make_label(root, 24, 105.0, 160.0)

	var bar := HBoxContainer.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 14)
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -190.0
	bar.offset_bottom = -90.0
	root.add_child(bar)

	_make_button(bar, "Undo", _on_undo)
	_make_button(bar, "Restart", _on_restart)
	hint_button = _make_button(bar, "Hint", _on_hint)
	next_button = _make_button(bar, "Next", _on_next)


func _make_label(parent: Control, font_size: int, top: float, bottom: float) -> Label:
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	label.offset_top = top
	label.offset_bottom = bottom
	label.offset_left = 20.0
	label.offset_right = -20.0
	parent.add_child(label)
	return label


func _make_button(parent: Control, text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(150, 90)
	b.add_theme_font_size_override("font_size", 28)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(callback)
	parent.add_child(b)
	return b


func _update_ui(message: String) -> void:
	if levels.is_empty():
		return
	var par: int = levels[level_index]["par"]
	title_label.text = "Level %d   Moves %d   Par %d" % [level_index + 1, moves, par]
	if message != "":
		status_label.text = message
	elif not won:
		status_label.text = ""
	hint_button.text = "Hint (%d)" % hints_left if hints_left > 0 else "Hint (ad)"
	next_button.text = "Next" if won else "Skip"
