extends Node2D
## Beam: start screen, worlds of levels; flip and drag mirrors to light every crystal.

const Rules := preload("res://scripts/beam_rules.gd")
const LevelSelect := preload("res://addons/studio_core/level_select.gd")
const Fx := preload("res://addons/studio_core/fx.gd")
const MascotView := preload("res://addons/studio_core/mascot_view.gd")

const LEVELS_PATH := "res://levels/levels.json"
const TAP_MAX_PX := 24.0
const ACCENT := Color("#4cc9f0")

const BG_COLOR := Color("#14142b")
const FLOOR_COLOR := Color("#23233f")
const WALL_COLOR := Color("#3d3d63")
const MIRROR_TILE_COLOR := Color("#2f2f55")
const MIRROR_COLOR := Color("#dfe7ff")
const HANDLE_COLOR := Color("#ffd166")
const PORTAL_COLORS := [Color("#c77dff"), Color("#ffd166"), Color("#06d6a0"), Color("#ef476f")]
## Beam colors by bit value: r=1, y=2, b=4, o=3, g=6, p=5, w=7.
const COLOR_BY_BITS := {
	1: Color("#ff4d6d"),
	2: Color("#ffd60a"),
	4: Color("#4cc9f0"),
	3: Color("#ff8c42"),
	6: Color("#38f2a0"),
	5: Color("#b388ff"),
	7: Color("#ffffff"),
}

var levels: Array = []
var worlds: Array = []
var level_index := 0
var lvl: Dictionary = {}
var fixed: Dictionary = {}
var movers: Array = []
var traced: Dictionary = {}
var history: Array = []
var taps := 0
var won := false
var in_menu := true
var hint: Dictionary = {}
var pulse := 0.0

var cell := 64.0
var origin := Vector2.ZERO

var _touch_start := Vector2.ZERO
var _touching := false
var _drag_index := -1
var _drag_pos := Vector2.ZERO
var _tex_cache := {}

var game_ui: Control
var menu: Control
var title_label: Label
var status_label: Label
var hint_button: Button
var next_button: Button
var mascot: Control


func _ready() -> void:
	_load_levels()
	_build_ui()
	get_viewport().size_changed.connect(_layout)
	show_menu()


func _load_levels() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(LEVELS_PATH))
	if data == null or not data.has("worlds"):
		push_error("Could not read " + LEVELS_PATH)
		return
	for wi in data["worlds"].size():
		var w: Dictionary = data["worlds"][wi]
		worlds.append({"name": w["name"], "intro": w["intro"], "start": levels.size(), "count": w["levels"].size()})
		for l in w["levels"]:
			l["world"] = wi
			levels.append(l)


## Optional art: res://assets/<name>.png is used if it exists, otherwise shapes are drawn.
func _tex(name: String) -> Texture2D:
	if not _tex_cache.has(name):
		var path := "res://assets/%s.png" % name
		_tex_cache[name] = load(path) if ResourceLoader.exists(path) else null
	return _tex_cache[name]


# ---------------------------------------------------------------- menu / flow

func show_menu() -> void:
	in_menu = true
	_drag_index = -1
	game_ui.visible = false
	menu.visible = true
	menu.refresh()
	queue_redraw()


func _on_level_chosen(index: int) -> void:
	menu.visible = false
	game_ui.visible = true
	in_menu = false
	_start_level(index)


func _start_level(index: int) -> void:
	if levels.is_empty():
		return
	level_index = clampi(index, 0, levels.size() - 1)
	lvl = Rules.parse(levels[level_index])
	fixed = lvl["fixed"].duplicate()
	movers = lvl["movers"].duplicate(true)
	history.clear()
	taps = 0
	won = false
	hint = {}
	_drag_index = -1
	_retrace()
	_layout()
	mascot.react("excited", 1.5)
	var w: Dictionary = worlds[levels[level_index]["world"]]
	if level_index == w["start"]:
		_update_ui(w["name"] + ": " + w["intro"])
	elif not movers.is_empty():
		_update_ui("Drag the mirrors with handles. Tap any mirror to flip it.")
	else:
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
	traced = Rules.trace(lvl, Rules.mirror_map(fixed, movers))
	queue_redraw()


# ---------------------------------------------------------------- input

func _cell_at(screen_pos: Vector2) -> Vector2i:
	return Vector2i(((screen_pos - origin) / cell).floor())


func _mover_at(c: Vector2i) -> int:
	for i in movers.size():
		if movers[i]["pos"] == c:
			return i
	return -1


func _unhandled_input(event: InputEvent) -> void:
	if in_menu:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_start = event.position
			_touching = true
			_drag_index = -1 if won else _mover_at(_cell_at(event.position))
			_drag_pos = event.position
		elif _touching:
			_touching = false
			var moved_px: float = (event.position - _touch_start).length()
			var c := _cell_at(event.position)
			if _drag_index >= 0 and moved_px > TAP_MAX_PX:
				drop_mover(_drag_index, c)
			elif moved_px <= TAP_MAX_PX:
				tap_cell(_cell_at(_touch_start))
			_drag_index = -1
			queue_redraw()
	elif event is InputEventScreenDrag and _drag_index >= 0:
		_drag_pos = event.position
		queue_redraw()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_Z: _on_undo()
			KEY_R: _on_restart()
			KEY_H: _on_hint()
			KEY_N: _on_next()
			KEY_ESCAPE, KEY_M: show_menu()


func _save_history() -> void:
	history.append({"fixed": fixed.duplicate(), "movers": movers.duplicate(true)})


## Flip the mirror (fixed or mover) at a cell.
func tap_cell(c: Vector2i) -> void:
	if won:
		return
	var mi := _mover_at(c)
	if mi >= 0:
		_save_history()
		movers[mi]["m"] = "\\" if movers[mi]["m"] == "/" else "/"
	elif fixed.has(c):
		_save_history()
		fixed[c] = "\\" if fixed[c] == "/" else "/"
	else:
		return
	_after_change()


func can_drop(c: Vector2i) -> bool:
	if c.x < 0 or c.y < 0 or c.x >= lvl["w"] or c.y >= lvl["h"]:
		return false
	if lvl["walls"].has(c) or lvl["portals"].has(c) or lvl["targets"].has(c) \
			or lvl["filters"].has(c) or lvl["tints"].has(c) or fixed.has(c) or _mover_at(c) >= 0:
		return false
	for e in lvl["emitters"]:
		if e["pos"] == c:
			return false
	return true


## Move a draggable mirror to an empty cell (keeps its angle).
func drop_mover(index: int, c: Vector2i) -> void:
	if won or index < 0 or index >= movers.size() or not can_drop(c):
		return
	_save_history()
	movers[index]["pos"] = c
	_after_change()


func _after_change() -> void:
	taps += 1
	mascot.poke()
	hint = {}
	_retrace()
	if traced["lit"].size() == lvl["targets"].size():
		won = true
		var par: int = levels[level_index]["par"]
		var stars := 3 if taps <= par else (2 if taps <= par + 2 else 1)
		Progress.record_stars(level_index, stars)
		mascot.react("cheering", 4.0)
		_update_ui("All crystals lit in %d moves (par %d)" % [taps, par], stars)
		var colors := []
		for p in lvl["targets"]:
			colors.append(COLOR_BY_BITS.get(lvl["targets"][p], Color.WHITE))
		Fx.burst(self, origin + Vector2(lvl["w"], lvl["h"]) * cell / 2.0, colors)
	else:
		_update_ui("")


func _on_undo() -> void:
	if history.is_empty() or in_menu:
		return
	var last: Dictionary = history.pop_back()
	fixed = last["fixed"]
	movers = last["movers"]
	taps -= 1
	won = false
	hint = {}
	_retrace()
	_update_ui("")


func _on_restart() -> void:
	if not in_menu:
		_start_level(level_index)


func _on_hint() -> void:
	if won or in_menu:
		return
	if Progress.hints > 0:
		Progress.hints -= 1
		_show_hint()
	else:
		Ads.show_rewarded(func():
			Progress.hints += 1
			_update_ui("You earned a hint. Tap Hint to use it."))


func _show_hint() -> void:
	mascot.react("thinking", 3.0)
	hint = Rules.next_hint(lvl, fixed, movers)
	if hint.is_empty():
		_update_ui("No hint from here. Try Restart.")
	elif hint["kind"] == "drag":
		_update_ui("Hint: drag the glowing mirror to the glowing square.")
	else:
		_update_ui("Hint: flip the glowing mirror.")
	queue_redraw()


func _can_go_next() -> bool:
	if won:
		return true
	return level_index + 1 < levels.size() and Progress.is_unlocked(level_index + 1)


func _on_next() -> void:
	if in_menu or not _can_go_next():
		return
	var finished_level := level_index + 1
	var go_next := func():
		if level_index + 1 >= levels.size():
			show_menu()
		else:
			_start_level(level_index + 1)
	if won:
		Ads.on_level_complete(finished_level, go_next)
	else:
		go_next.call()


# ---------------------------------------------------------------- drawing

func _process(delta: float) -> void:
	pulse += delta
	if not in_menu:
		queue_redraw()


func _center(p: Vector2i) -> Vector2:
	return origin + (Vector2(p) + Vector2(0.5, 0.5)) * cell


func _cell_rect(p: Vector2i) -> Rect2:
	return Rect2(origin + Vector2(p) * cell, Vector2(cell, cell))


func _draw() -> void:
	if in_menu:
		return
	var bg := _tex("background_world%d" % (levels[level_index]["world"] + 1))
	if bg:
		draw_texture_rect(bg, Rect2(Vector2.ZERO, get_viewport_rect().size), false)
	else:
		draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), BG_COLOR)
	if lvl.is_empty():
		return
	var all_mirrors := Rules.mirror_map(fixed, movers)
	var floor_tex := _tex("floor")
	var wall_tex := _tex("wall")
	for y in lvl["h"]:
		for x in lvl["w"]:
			var p := Vector2i(x, y)
			var is_wall: bool = lvl["walls"].has(p)
			var tex := wall_tex if is_wall else floor_tex
			if tex:
				draw_texture_rect(tex, _cell_rect(p), false)
			else:
				var col := WALL_COLOR if is_wall else (MIRROR_TILE_COLOR if all_mirrors.has(p) else FLOOR_COLOR)
				draw_rect(_cell_rect(p).grow(-2.0), col)

	# Colored glass (tints) under the beams.
	for p in lvl["tints"]:
		var col: Color = COLOR_BY_BITS[lvl["tints"][p]]
		var r := _cell_rect(p).grow(-6.0)
		draw_rect(r, Color(col, 0.35))
		draw_rect(r, Color(col, 0.9), false, 3.0)
		draw_line(r.position + Vector2(r.size.x * 0.2, r.size.y * 0.8), r.position + Vector2(r.size.x * 0.8, r.size.y * 0.2), Color(1, 1, 1, 0.35), 3.0)

	# Portal pads.
	for p in lvl["portals"]:
		var id: String = lvl["portal_ids"][p]
		var col: Color = PORTAL_COLORS[(int(id) - 1) % PORTAL_COLORS.size()]
		var c := _center(p)
		draw_circle(c, cell * 0.38, Color(col, 0.2))
		for k in 3:
			var a := -pulse * 2.0 + k * TAU / 3.0
			draw_arc(c, cell * (0.16 + 0.09 * k), a, a + PI * 0.9, 16, col, 3.0)

	# Hint highlight.
	if not hint.is_empty():
		var glow := Color(1, 0.9, 0.3, 0.35 + 0.25 * sin(pulse * 6.0))
		if hint["kind"] == "flip":
			draw_rect(_cell_rect(hint["cell"]).grow(-2.0), glow)
		else:
			draw_rect(_cell_rect(hint["from"]).grow(-2.0), glow)
			draw_rect(_cell_rect(hint["to"]).grow(-2.0), glow)
			draw_dashed_line(_center(hint["from"]), _center(hint["to"]), Color(1, 0.9, 0.3, 0.8), 4.0, 12.0)

	_draw_beams()

	# Filters: colored gates on top of the beams.
	for p in lvl["filters"]:
		var col: Color = COLOR_BY_BITS[lvl["filters"][p]]
		var r := _cell_rect(p).grow(-8.0)
		draw_rect(r, Color(col, 0.15))
		draw_rect(r, col, false, 4.0)
		for k in 3:
			var x := r.position.x + r.size.x * (0.25 + 0.25 * k)
			draw_line(Vector2(x, r.position.y + 4), Vector2(x, r.end.y - 4), Color(col, 0.8), 3.0)

	for p in fixed:
		_draw_mirror(_center(p), fixed[p], false, 1.0)
	for i in movers.size():
		if i == _drag_index:
			continue
		_draw_mirror(_center(movers[i]["pos"]), movers[i]["m"], true, 1.0)
	if _drag_index >= 0 and _drag_index < movers.size():
		var over := _cell_at(_drag_pos)
		if can_drop(over):
			draw_rect(_cell_rect(over).grow(-2.0), Color(HANDLE_COLOR, 0.25))
		_draw_mirror(_drag_pos, movers[_drag_index]["m"], true, 1.15)

	for e in lvl["emitters"]:
		_draw_emitter(e)
	for p in lvl["targets"]:
		_draw_crystal(p, lvl["targets"][p], traced["lit"].has(p))


func _draw_beams() -> void:
	var shimmer := 0.85 + 0.15 * sin(pulse * 8.0)
	for beam in traced["beams"]:
		var segments: Array = beam["segments"]
		for si in segments.size():
			var seg: Dictionary = segments[si]
			var col: Color = COLOR_BY_BITS.get(seg["color"], Color.WHITE)
			var pts := PackedVector2Array()
			for p in seg["cells"]:
				pts.append(_center(p))
			if si == segments.size() - 1 and not beam["stopped_at_target"]:
				var last: Vector2i = seg["cells"][-1]
				pts.append(_center(last) + Vector2(beam["end_dir"]) * cell * 0.5)
			if pts.size() < 2:
				continue
			draw_polyline(pts, Color(col, 0.18), cell * 0.32, true)
			draw_polyline(pts, Color(col, 0.45 * shimmer), cell * 0.16, true)
			draw_polyline(pts, col.lightened(0.5), cell * 0.06, true)


func _draw_mirror(c: Vector2, m: String, draggable: bool, size_scale: float) -> void:
	var r := cell * 0.36 * size_scale
	if draggable:
		var box := Rect2(c - Vector2(r, r) * 1.15, Vector2(r, r) * 2.3)
		draw_rect(box, Color(HANDLE_COLOR, 0.12))
		var k := r * 0.45
		for corner in [box.position, Vector2(box.end.x, box.position.y), box.end, Vector2(box.position.x, box.end.y)]:
			var sx := 1.0 if corner.x == box.position.x else -1.0
			var sy := 1.0 if corner.y == box.position.y else -1.0
			draw_line(corner, corner + Vector2(sx * k, 0), HANDLE_COLOR, 4.0)
			draw_line(corner, corner + Vector2(0, sy * k), HANDLE_COLOR, 4.0)
	var tex := _tex("mirror_mover" if draggable else "mirror")
	if tex:
		draw_set_transform(c, 0.0 if m == "/" else PI / 2.0, Vector2.ONE)
		draw_texture_rect(tex, Rect2(-Vector2(r, r), Vector2(r, r) * 2.0), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	var a := c + (Vector2(-r, r) if m == "/" else Vector2(-r, -r))
	var b := c + (Vector2(r, -r) if m == "/" else Vector2(r, r))
	draw_line(a, b, MIRROR_COLOR, maxf(4.0, cell * 0.09), true)


func _draw_emitter(e: Dictionary) -> void:
	var col: Color = COLOR_BY_BITS.get(e["color"], Color.WHITE)
	var c := _center(e["pos"])
	var s := cell * 0.34
	draw_rect(Rect2(c - Vector2(s, s), Vector2(s, s) * 2.0), col.darkened(0.55))
	draw_rect(Rect2(c - Vector2(s, s), Vector2(s, s) * 2.0), col, false, 3.0)
	var d := Vector2(e["dir"])
	var side := Vector2(-d.y, d.x)
	var tip := c + d * s * 0.85
	draw_colored_polygon(PackedVector2Array([tip, c - d * s * 0.3 + side * s * 0.55, c - d * s * 0.3 - side * s * 0.55]), col)


func _draw_crystal(p: Vector2i, bits: int, lit: bool) -> void:
	var col: Color = COLOR_BY_BITS.get(bits, Color.WHITE)
	var c := _center(p)
	var r := cell * 0.34
	var tex := _tex("crystal_lit" if lit else "crystal")
	if tex:
		draw_texture_rect(tex, Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0), false, col)
		return
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
	game_ui = Control.new()
	game_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	game_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(game_ui)

	title_label = _make_label(game_ui, 34, 40.0, 100.0)
	status_label = _make_label(game_ui, 24, 105.0, 160.0)
	mascot = MascotView.new()
	mascot.load_poses("res://assets/")
	mascot.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	mascot.offset_left = -140.0
	mascot.offset_right = -10.0
	mascot.offset_top = 30.0
	mascot.offset_bottom = 160.0
	game_ui.add_child(mascot)
	if mascot.visible:
		title_label.offset_right = -150.0
		status_label.offset_right = -150.0

	var bar := HBoxContainer.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 10)
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -190.0
	bar.offset_bottom = -90.0
	game_ui.add_child(bar)

	_make_button(bar, "Menu", show_menu)
	_make_button(bar, "Undo", _on_undo)
	_make_button(bar, "Restart", _on_restart)
	hint_button = _make_button(bar, "Hint", _on_hint)
	next_button = _make_button(bar, "Next", _on_next)

	var menu_layer := CanvasLayer.new()
	menu_layer.layer = 10
	add_child(menu_layer)
	menu = LevelSelect.new()
	menu.setup("Beam", worlds, ACCENT, _tex("mascot"), _tex("menu_background"))
	menu.level_chosen.connect(_on_level_chosen)
	menu_layer.add_child(menu)


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
	b.custom_minimum_size = Vector2(128, 90)
	b.add_theme_font_size_override("font_size", 26)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(callback)
	parent.add_child(b)
	return b


func _update_ui(message: String, stars: int = 0) -> void:
	if levels.is_empty():
		return
	var par: int = levels[level_index]["par"]
	var w: Dictionary = worlds[levels[level_index]["world"]]
	title_label.text = "%s %d-%d   Moves %d   Par %d" % [w["name"], level_index - int(w["start"]) + 1, int(w["count"]), taps, par]
	if message != "":
		status_label.text = message + ("   " + "*".repeat(stars) if stars > 0 else "")
	elif not won:
		status_label.text = ""
	hint_button.text = "Hint %d" % Progress.hints if Progress.hints > 0 else "Hint (ad)"
	next_button.disabled = not _can_go_next()
