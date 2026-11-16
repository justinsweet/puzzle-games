extends Node2D
## Beam prototype: tap mirrors to steer colored beams into matching crystals.

const Rules := preload("res://scripts/beam_rules.gd")

const LEVELS_PATH := "res://levels/levels.json"
const TAP_MAX_PX := 24.0
const FREE_HINTS := 3

const BG_COLOR := Color("#14142b")
const FLOOR_COLOR := Color("#23233f")
const WALL_COLOR := Color("#3d3d63")
const MIRROR_TILE_COLOR := Color("#2f2f55")
const MIRROR_COLOR := Color("#dfe7ff")
const BEAM_COLORS := {
	"r": Color("#ff4d6d"),
	"g": Color("#38f2a0"),
	"b": Color("#4cc9f0"),
}

var levels: Array = []
var level_index := 0
var lvl: Dictionary = {}
var mirrors: Dictionary = {}
var traced: Dictionary = {}
var history: Array = []
var taps := 0
var won := false
var hints_left := FREE_HINTS
var hint_cell := Vector2i(-1, -1)
var pulse := 0.0

var cell := 64.0
var origin := Vector2.ZERO

var _touch_start := Vector2.ZERO
var _touching := false

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
	var data = JSON.parse_string(FileAccess.get_file_as_string(LEVELS_PATH))
	if data == null or not data.has("levels"):
		push_error("Could not read " + LEVELS_PATH)
		return
	levels = data["levels"]


func _start_level(index: int) -> void:
	if levels.is_empty():
		return
	level_index = clampi(index, 0, levels.size() - 1)
	lvl = Rules.parse(levels[level_index])
	mirrors = lvl["mirrors"].duplicate()
	history.clear()
	taps = 0
	won = false
	hint_cell = Vector2i(-1, -1)
	_retrace()
	_layout()
	_update_ui("Tap a mirror to flip it.")


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


func _retrace() -> void:
	traced = Rules.trace(lvl, mirrors)
	queue_redraw()


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_start = event.position
			_touching = true
		elif _touching:
			_touching = false
			if (event.position - _touch_start).length() <= TAP_MAX_PX:
				var c := Vector2i(((event.position - origin) / cell).floor())
				tap_cell(c)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_Z: _on_undo()
			KEY_R: _on_restart()
			KEY_H: _on_hint()
			KEY_N: _on_next()
			KEY_P: _start_level(level_index - 1)


func tap_cell(c: Vector2i) -> void:
	if won or not mirrors.has(c):
		return
	history.append(mirrors.duplicate())
	mirrors[c] = "\\" if mirrors[c] == "/" else "/"
	taps += 1
	hint_cell = Vector2i(-1, -1)
	_retrace()
	if traced["lit"].size() == lvl["targets"].size():
		won = true
		var par: int = levels[level_index]["par"]
		var stars := 3 if taps <= par else (2 if taps <= par + 2 else 1)
		_update_ui("All crystals lit in %d taps (par %d)  -  Stars: %d/3" % [taps, par, stars])
	else:
		_update_ui("")


func _on_undo() -> void:
	if history.is_empty():
		return
	mirrors = history.pop_back()
	taps -= 1
	won = false
	_retrace()
	_update_ui("")


func _on_restart() -> void:
	_start_level(level_index)


func _on_hint() -> void:
	if won:
		return
	if hints_left > 0:
		hints_left -= 1
		_show_hint()
	else:
		Ads.show_rewarded(func():
			hints_left += 1
			_update_ui("You earned a hint. Tap Hint to use it."))


func _show_hint() -> void:
	var path := Rules.solve(lvl, mirrors)
	if path.is_empty():
		_update_ui("No solution from here. Try Restart.")
		return
	hint_cell = path[0]
	_update_ui("Hint: flip the glowing mirror  (%d taps left at best)" % path.size())
	queue_redraw()


func _on_next() -> void:
	var finished_level := level_index + 1
	var go_next := func(): _start_level((level_index + 1) % levels.size())
	if won:
		Ads.on_level_complete(finished_level, go_next)
	else:
		go_next.call()  # prototype: allow skipping while testing


# ---------------------------------------------------------------- drawing

func _process(delta: float) -> void:
	pulse += delta
	queue_redraw()  # beams and lit crystals shimmer


func _center(p: Vector2i) -> Vector2:
	return origin + (Vector2(p) + Vector2(0.5, 0.5)) * cell


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), BG_COLOR)
	if lvl.is_empty():
		return
	for y in lvl["h"]:
		for x in lvl["w"]:
			var p := Vector2i(x, y)
			var rect := Rect2(origin + Vector2(p) * cell, Vector2(cell, cell)).grow(-2.0)
			var col := FLOOR_COLOR
			if lvl["walls"].has(p):
				col = WALL_COLOR
			elif mirrors.has(p):
				col = MIRROR_TILE_COLOR
			draw_rect(rect, col)
	if hint_cell != Vector2i(-1, -1):
		var glow := 0.35 + 0.25 * sin(pulse * 6.0)
		draw_rect(Rect2(origin + Vector2(hint_cell) * cell, Vector2(cell, cell)).grow(-2.0), Color(1, 0.9, 0.3, glow))

	_draw_beams()

	for p in mirrors:
		var c := _center(p)
		var r := cell * 0.36
		var a: Vector2
		var b: Vector2
		if mirrors[p] == "/":
			a = c + Vector2(-r, r)
			b = c + Vector2(r, -r)
		else:
			a = c + Vector2(-r, -r)
			b = c + Vector2(r, r)
		draw_line(a, b, MIRROR_COLOR, maxf(4.0, cell * 0.09), true)

	for e in lvl["emitters"]:
		_draw_emitter(e)

	for p in lvl["targets"]:
		_draw_crystal(p, lvl["targets"][p], traced["lit"].has(p))


func _draw_beams() -> void:
	for beam in traced["beams"]:
		var col: Color = BEAM_COLORS.get(beam["color"], Color.WHITE)
		var pts := PackedVector2Array([_center(beam["start"])])
		for p in beam["cells"]:
			pts.append(_center(p))
		var cells: Array = beam["cells"]
		var last: Vector2i = beam["start"] if cells.is_empty() else cells[-1]
		var ends_on_crystal: bool = lvl["targets"].has(last) and not cells.is_empty()
		if not ends_on_crystal:
			pts.append(_center(last) + Vector2(beam["end_dir"]) * cell * 0.5)
		var shimmer := 0.85 + 0.15 * sin(pulse * 8.0)
		draw_polyline(pts, Color(col, 0.18), cell * 0.32, true)
		draw_polyline(pts, Color(col, 0.45 * shimmer), cell * 0.16, true)
		draw_polyline(pts, col.lightened(0.5), cell * 0.06, true)


func _draw_emitter(e: Dictionary) -> void:
	var col: Color = BEAM_COLORS.get(e["color"], Color.WHITE)
	var c := _center(e["pos"])
	var s := cell * 0.34
	draw_rect(Rect2(c - Vector2(s, s), Vector2(s, s) * 2.0), col.darkened(0.55))
	draw_rect(Rect2(c - Vector2(s, s), Vector2(s, s) * 2.0), col, false, 3.0)
	var d := Vector2(e["dir"])
	var side := Vector2(-d.y, d.x)
	var tip := c + d * s * 0.85
	draw_colored_polygon(PackedVector2Array([tip, c - d * s * 0.3 + side * s * 0.55, c - d * s * 0.3 - side * s * 0.55]), col)


func _draw_crystal(p: Vector2i, color_key: String, lit: bool) -> void:
	var col: Color = BEAM_COLORS.get(color_key, Color.WHITE)
	var c := _center(p)
	var r := cell * 0.34
	var shape := PackedVector2Array([c + Vector2(0, -r), c + Vector2(r * 0.75, 0), c + Vector2(0, r), c + Vector2(-r * 0.75, 0)])
	if lit:
		draw_circle(c, r * (1.25 + 0.1 * sin(pulse * 5.0)), Color(col, 0.25))
		draw_colored_polygon(shape, col.lightened(0.2))
	else:
		draw_colored_polygon(shape, col.darkened(0.7))
	var outline := shape.duplicate()
	outline.append(shape[0])
	draw_polyline(outline, col, 3.0, true)


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
	title_label.text = "Level %d   Taps %d   Par %d" % [level_index + 1, taps, par]
	if message != "":
		status_label.text = message
	elif not won:
		status_label.text = ""
	hint_button.text = "Hint (%d)" % hints_left if hints_left > 0 else "Hint (ad)"
	next_button.text = "Next" if won else "Skip"
