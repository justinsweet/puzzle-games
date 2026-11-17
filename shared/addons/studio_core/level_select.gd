extends Control
## Start screen + world/level select, shared by every game.
##
## Usage from a game:
##   var menu := preload("res://addons/studio_core/level_select.gd").new()
##   menu.setup("Tilt", worlds, accent_color, mascot_texture_or_null)
##   menu.level_chosen.connect(_on_level_chosen)
##   some_canvas_layer.add_child(menu)
## `worlds` is an Array of {"name", "intro", "start", "count"} (start = first level index).

signal level_chosen(index: int)

const Fx := preload("res://addons/studio_core/fx.gd")

var game_title := ""
var worlds: Array = []
var accent := Color("#ffb703")
var mascot_texture: Texture2D
var background_texture: Texture2D

var _list: VBoxContainer
var _stars_label: Label
var _time := 0.0
var _mascot: Control
var _bubbles: Array = []


func setup(title: String, world_list: Array, accent_color: Color, mascot: Texture2D = null, background: Texture2D = null) -> void:
	game_title = title
	worlds = world_list
	accent = accent_color
	mascot_texture = mascot
	background_texture = background


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var rng := RandomNumberGenerator.new()
	for i in 18:
		_bubbles.append({"x": rng.randf(), "y": rng.randf(), "r": rng.randf_range(8, 40), "speed": rng.randf_range(0.01, 0.04)})
	_build()
	refresh()


func _process(delta: float) -> void:
	if not visible:
		return
	_time += delta
	for b in _bubbles:
		b["y"] = fposmod(b["y"] - b["speed"] * delta, 1.2)
	queue_redraw()
	if _mascot:
		_mascot.queue_redraw()


func _draw() -> void:
	var s := size
	if background_texture:
		draw_texture_rect(background_texture, Rect2(Vector2.ZERO, s), false)
	else:
		draw_rect(Rect2(Vector2.ZERO, s), accent.darkened(0.82))
		for b in _bubbles:
			draw_circle(Vector2(b["x"] * s.x, b["y"] * s.y), b["r"], Color(accent, 0.08))


func _build() -> void:
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 24
	col.offset_right = -24
	col.offset_top = 40
	col.offset_bottom = -30
	col.add_theme_constant_override("separation", 10)
	add_child(col)

	_mascot = _Mascot.new()
	_mascot.custom_minimum_size = Vector2(0, 170)
	_mascot.menu = self
	col.add_child(_mascot)

	var title := Label.new()
	title.text = game_title
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 84)
	title.add_theme_color_override("font_color", accent.lightened(0.3))
	col.add_child(title)

	_stars_label = Label.new()
	_stars_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stars_label.add_theme_font_size_override("font_size", 26)
	col.add_child(_stars_label)

	var play := Button.new()
	play.text = "Play"
	play.custom_minimum_size = Vector2(0, 100)
	play.add_theme_font_size_override("font_size", 44)
	play.focus_mode = Control.FOCUS_NONE
	play.pressed.connect(func(): level_chosen.emit(Progress.next_unplayed(_level_count())))
	col.add_child(play)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 12)
	scroll.add_child(_list)

	var tools := HBoxContainer.new()
	tools.alignment = BoxContainer.ALIGNMENT_CENTER
	tools.add_theme_constant_override("separation", 12)
	col.add_child(tools)
	var unlock := CheckButton.new()
	unlock.text = "Unlock all (testing)"
	unlock.focus_mode = Control.FOCUS_NONE
	unlock.button_pressed = Progress.unlock_all
	unlock.toggled.connect(func(on): Progress.unlock_all = on; refresh())
	tools.add_child(unlock)
	var reset := Button.new()
	reset.text = "Reset progress"
	reset.focus_mode = Control.FOCUS_NONE
	reset.pressed.connect(func(): Progress.reset(); unlock.button_pressed = false; refresh())
	tools.add_child(reset)


func _level_count() -> int:
	var n := 0
	for w in worlds:
		n += int(w["count"])
	return n


## Rebuilds the level grid (call after progress changes).
func refresh() -> void:
	if _list == null:
		return
	for child in _list.get_children():
		child.queue_free()
	var max_stars := _level_count() * 3
	_stars_label.text = "Stars collected: %d / %d" % [Progress.total_stars(), max_stars]
	for w in worlds:
		var start: int = w["start"]
		var count: int = w["count"]
		var unlocked := Progress.is_unlocked(start)
		var header := Label.new()
		header.text = w["name"] if unlocked else w["name"] + "  (locked)"
		header.add_theme_font_size_override("font_size", 34)
		header.add_theme_color_override("font_color", accent.lightened(0.2) if unlocked else Color(1, 1, 1, 0.4))
		_list.add_child(header)
		var grid := GridContainer.new()
		grid.columns = 5
		grid.add_theme_constant_override("h_separation", 10)
		grid.add_theme_constant_override("v_separation", 10)
		_list.add_child(grid)
		for i in range(start, start + count):
			var b := _LevelButton.new()
			b.level = i
			b.stars = Progress.stars(i)
			b.locked = not Progress.is_unlocked(i)
			b.accent = accent
			b.text = str(i + 1)
			b.disabled = b.locked
			b.custom_minimum_size = Vector2(120, 120)
			b.add_theme_font_size_override("font_size", 36)
			b.focus_mode = Control.FOCUS_NONE
			b.pressed.connect(func(): level_chosen.emit(i))
			grid.add_child(b)


class _LevelButton extends Button:
	var level := 0
	var stars := 0
	var locked := false
	var accent := Color.WHITE

	func _draw() -> void:
		if locked:
			return
		var y := size.y - 22.0
		for k in 3:
			var c := Vector2(size.x / 2.0 + (k - 1) * 26.0, y)
			var pts := Fx.star_points(c, 11.0)
			if k < stars:
				draw_colored_polygon(pts, Color("#ffd60a"))
			else:
				var outline := pts.duplicate()
				outline.append(pts[0])
				draw_polyline(outline, Color(1, 1, 1, 0.35), 2.0)


class _Mascot extends Control:
	## Placeholder character until real art exists: a bouncing, blinking blob.
	var menu: Control

	func _draw() -> void:
		var t: float = menu._time
		var c := Vector2(size.x / 2.0, size.y / 2.0 + sin(t * 2.4) * 10.0)
		if menu.mascot_texture:
			var tex: Texture2D = menu.mascot_texture
			var h := size.y * 0.95
			var w: float = h * tex.get_width() / maxf(1.0, float(tex.get_height()))
			draw_texture_rect(tex, Rect2(c - Vector2(w, h) / 2.0, Vector2(w, h)), false)
			return
		var squash := 1.0 + sin(t * 4.8) * 0.04
		var r := 62.0
		var body := PackedVector2Array()
		for i in 40:
			var a := TAU * i / 40.0
			body.append(c + Vector2(cos(a) * r * squash, sin(a) * r / squash))
		draw_circle(c + Vector2(0, r + 8), r * 0.7, Color(0, 0, 0, 0.18))
		draw_colored_polygon(body, menu.accent)
		draw_circle(c + Vector2(-r * 0.35, -r * 0.4), r * 0.22, Color(1, 1, 1, 0.35))
		var blink := fmod(t, 3.2) < 0.12
		for side in [-1, 1]:
			var e := c + Vector2(side * r * 0.32, -r * 0.05)
			if blink:
				draw_line(e - Vector2(9, 0), e + Vector2(9, 0), Color("#1d1d1d"), 4.0)
			else:
				draw_circle(e, 13.0, Color.WHITE)
				draw_circle(e + Vector2(3, 2), 6.5, Color("#1d1d1d"))
		draw_arc(c + Vector2(0, r * 0.2), 16.0, 0.2, PI - 0.2, 16, Color("#1d1d1d"), 4.0)
