extends Node2D
## Tilt: start screen, worlds of levels, swipe to slide marbles into matching holes.

const Rules := preload("res://scripts/tilt_rules.gd")
const LevelSelect := preload("res://addons/studio_core/level_select.gd")
const Fx := preload("res://addons/studio_core/fx.gd")
const MascotView := preload("res://addons/studio_core/mascot_view.gd")

const LEVELS_PATH := "res://levels/levels.json"
const SWIPE_MIN_PX := 40.0
const SECONDS_PER_CELL := 0.06
const ACCENT := Color("#f4a261")

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
const PAD_COLORS := [Color("#c77dff"), Color("#ffd166"), Color("#06d6a0"), Color("#ef476f")]

var levels: Array = []   # flat list; each level also has "world" (index)
var worlds: Array = []   # {"name", "intro", "start", "count"}
var level_index := 0
var lvl: Dictionary = {}
var marbles: Array = []
var holes: Dictionary = {}
var history: Array = []
var moves := 0
var won := false
var in_menu := true

var animating := false
var anim_t := 0.0
var anim_marbles: Array = []
var anim_max_len := 0.0
var pulse := 0.0

var cell := 64.0
var origin := Vector2.ZERO

var _touch_start := Vector2.ZERO
var _touching := false
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
	animating = false
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
	lvl = Rules.parse(levels[level_index]["rows"])
	marbles = lvl["marbles"].duplicate(true)
	holes = lvl["holes"].duplicate()
	history.clear()
	moves = 0
	won = false
	animating = false
	_layout()
	mascot.react("excited", 1.5)
	var w: Dictionary = worlds[levels[level_index]["world"]]
	if level_index == w["start"]:
		_update_ui(w["name"] + ": " + w["intro"])
	else:
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
	if in_menu:
		return
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
			KEY_ESCAPE, KEY_M: show_menu()


# ---------------------------------------------------------------- moves

## Number of cells a path covers (a teleport jump counts as zero).
static func _path_len(path: Array) -> float:
	var n := 0.0
	for i in range(1, path.size()):
		if path[i] != null and path[i - 1] != null:
			n += 1.0
	return n


## Position (in cells) after travelling s cells along a path.
static func _pos_along(path: Array, s: float) -> Vector2:
	var pos := Vector2(path[0])
	var left := s
	for i in range(1, path.size()):
		if path[i] == null:
			continue
		if path[i - 1] == null:
			pos = Vector2(path[i])  # came out of a teleport pad
			continue
		var step := Vector2(path[i]) - Vector2(path[i - 1])
		if left >= 1.0:
			pos = Vector2(path[i])
			left -= 1.0
		else:
			return Vector2(path[i - 1]) + step * left
	return pos


func _try_move(dir: String) -> void:
	if animating or won or lvl.is_empty():
		return
	mascot.poke()
	var r := Rules.slide(lvl["w"], lvl["h"], lvl["walls"], lvl["portals"], marbles, holes, dir)
	var moved := false
	anim_max_len = 0.0
	for m in r["marbles"]:
		var length := _path_len(m["path"])
		if m["pos"] != m["from"] or length > 0.0:
			moved = true
		anim_max_len = maxf(anim_max_len, length)
	if not moved:
		return
	history.append({"marbles": marbles.duplicate(true), "holes": holes.duplicate()})
	moves += 1
	anim_marbles = r["marbles"]
	marbles = []
	for m in r["marbles"]:
		if not m["dropped"]:
			marbles.append({"pos": m["pos"], "color": m["color"]})
	holes = r["holes"]
	animating = true
	anim_t = 0.0
	var tween := create_tween()
	tween.tween_property(self, "anim_t", 1.0, SECONDS_PER_CELL * anim_max_len + 0.04)
	tween.finished.connect(_on_move_finished)
	_update_ui("")


func _on_move_finished() -> void:
	animating = false
	queue_redraw()
	if marbles.is_empty():
		won = true
		var par: int = levels[level_index]["par"]
		var stars := 3 if moves <= par else (2 if moves <= par + 3 else 1)
		Progress.record_stars(level_index, stars)
		mascot.react("cheering", 4.0)
		_update_ui("Solved in %d moves (par %d)" % [moves, par], stars)
		var colors := []
		for k in MARBLE_COLORS:
			colors.append(MARBLE_COLORS[k])
		Fx.burst(self, origin + Vector2(lvl["w"], lvl["h"]) * cell / 2.0, colors)


func _on_undo() -> void:
	if animating or history.is_empty() or in_menu:
		return
	var last: Dictionary = history.pop_back()
	marbles = last["marbles"]
	holes = last["holes"]
	moves -= 1
	won = false
	queue_redraw()
	_update_ui("")


func _on_restart() -> void:
	if not animating and not in_menu:
		_start_level(level_index)


func _on_hint() -> void:
	if animating or won or in_menu:
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
	var path := Rules.solve(lvl["w"], lvl["h"], lvl["walls"], lvl["portals"], marbles, holes)
	if path.is_empty():
		_update_ui("No solution from here. Try Undo or Restart.")
		return
	var names := {"U": "UP", "D": "DOWN", "L": "LEFT", "R": "RIGHT"}
	_update_ui("Hint: swipe %s  (%d moves left at best)" % [names[path[0]], path.size()])


func _can_go_next() -> bool:
	if won:
		return true
	return level_index + 1 < levels.size() and Progress.is_unlocked(level_index + 1)


func _on_next() -> void:
	if animating or in_menu or not _can_go_next():
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


func _cell_center(p: Vector2) -> Vector2:
	return origin + (p + Vector2(0.5, 0.5)) * cell


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
	var floor_tex := _tex("floor")
	var wall_tex := _tex("wall")
	for y in lvl["h"]:
		for x in lvl["w"]:
			var rect := Rect2(origin + Vector2(x, y) * cell, Vector2(cell, cell))
			var is_wall: bool = lvl["walls"].has(Vector2i(x, y))
			var tex := wall_tex if is_wall else floor_tex
			if tex:
				draw_texture_rect(tex, rect, false)
			else:
				draw_rect(rect.grow(-2.0), WALL_COLOR if is_wall else FLOOR_COLOR)

	# Teleport pads: swirling rings, linked pads share a color.
	for p in lvl["portals"]:
		var id: String = lvl["portal_ids"][p]
		var col: Color = PAD_COLORS[(int(id) - 1) % PAD_COLORS.size()]
		var c := _cell_center(Vector2(p))
		var pad_tex := _tex("pad_%s" % id)
		if pad_tex:
			draw_texture_rect(pad_tex, Rect2(c - Vector2(cell, cell) / 2.0, Vector2(cell, cell)), false)
			continue
		draw_circle(c, cell * 0.38, Color(col, 0.25))
		for k in 3:
			var a := pulse * 2.5 + k * TAU / 3.0
			draw_arc(c, cell * (0.18 + 0.08 * k), a, a + PI * 0.9, 16, col, 3.0)

	# Holes: open = colored ring; filled = solid dim circle.
	var open_now := holes.duplicate()
	if animating:
		for m in anim_marbles:
			if m["dropped"]:
				open_now[m["pos"]] = m["color"]
	for p in lvl["holes"]:
		var key: String = lvl["holes"][p]
		var col: Color = MARBLE_COLORS.get(key, Color.WHITE)
		var c := _cell_center(Vector2(p))
		var hole_tex := _tex("hole_%s" % key)
		if hole_tex and open_now.has(p):
			draw_texture_rect(hole_tex, Rect2(c - Vector2(cell, cell) / 2.0, Vector2(cell, cell)), false)
		elif open_now.has(p):
			draw_circle(c, cell * 0.32, Color(0, 0, 0, 0.35))
			draw_arc(c, cell * 0.30, 0.0, TAU, 40, col, maxf(3.0, cell * 0.08))
		else:
			draw_circle(c, cell * 0.30, col.darkened(0.45))

	if animating:
		for m in anim_marbles:
			var length := _path_len(m["path"])
			var travelled := minf(length, anim_t * anim_max_len)
			var pos := _pos_along(m["path"], travelled)
			var size_scale := 1.0
			if m["dropped"] and travelled >= length:
				size_scale = 0.6
			_draw_marble(_cell_center(pos), m["color"], size_scale)
	else:
		for m in marbles:
			_draw_marble(_cell_center(Vector2(m["pos"])), m["color"], 1.0)


func _draw_marble(c: Vector2, color_key: String, size_scale: float) -> void:
	var r := cell * 0.36 * size_scale
	var tex := _tex("marble_%s" % color_key)
	if tex:
		draw_texture_rect(tex, Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0), false)
		return
	var col: Color = MARBLE_COLORS.get(color_key, Color.WHITE)
	draw_circle(c + Vector2(0, r * 0.12), r, Color(0, 0, 0, 0.3))
	draw_circle(c, r, col)
	draw_circle(c + Vector2(-r * 0.35, -r * 0.35), r * 0.28, Color(1, 1, 1, 0.45))


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
	menu.setup("Tilt", worlds, ACCENT, _tex("mascot"), _tex("menu_background"))
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
	title_label.text = "%s %d-%d   Moves %d   Par %d" % [w["name"], level_index - int(w["start"]) + 1, int(w["count"]), moves, par]
	if message != "":
		status_label.text = message + ("   " + "*".repeat(stars) if stars > 0 else "")
	elif not won:
		status_label.text = ""
	hint_button.text = "Hint %d" % Progress.hints if Progress.hints > 0 else "Hint (ad)"
	next_button.disabled = not _can_go_next()
