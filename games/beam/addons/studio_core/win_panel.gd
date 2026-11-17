extends Control
## "Level complete" screen shared by every game: stars pop in one by one, then
## Replay / Next / Menu. Usage:
##   var panel := preload("res://addons/studio_core/win_panel.gd").new()
##   panel.setup(accent_color, mascot_texture_or_null)
##   panel.next_pressed.connect(...); panel.replay_pressed.connect(...); panel.menu_pressed.connect(...)
##   canvas_layer.add_child(panel)
##   panel.show_result("Meadow 3-12", 3, moves, par, has_next)

signal next_pressed
signal replay_pressed
signal menu_pressed

const Fx := preload("res://addons/studio_core/fx.gd")
const STAR_GOLD := Color("#ffd60a")

var accent := Color("#ffb703")
var mascot_texture: Texture2D

var _stars := 0
var _shown := 0.0          # how many stars have popped in so far (animated)
var _time := 0.0
var _card: Panel
var _title: Label
var _detail: Label
var _next_button: Button
var _star_area: Control


func setup(accent_color: Color, mascot: Texture2D = null) -> void:
	accent = accent_color
	mascot_texture = mascot


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	_card = Panel.new()
	_card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_card.custom_minimum_size = Vector2(560, 640)
	_card.offset_left = -280
	_card.offset_right = 280
	_card.offset_top = -330
	_card.offset_bottom = 310
	var style := StyleBoxFlat.new()
	style.bg_color = accent.darkened(0.78)
	style.border_color = accent
	style.set_border_width_all(4)
	style.set_corner_radius_all(28)
	_card.add_theme_stylebox_override("panel", style)
	add_child(_card)

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 30
	col.offset_right = -30
	col.offset_top = 24
	col.offset_bottom = -30
	col.add_theme_constant_override("separation", 12)
	_card.add_child(col)

	_star_area = _StarArea.new()
	_star_area.panel = self
	_star_area.custom_minimum_size = Vector2(0, 250)
	col.add_child(_star_area)

	_title = Label.new()
	_title.text = "Level complete!"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 46)
	_title.add_theme_color_override("font_color", accent.lightened(0.35))
	col.add_child(_title)

	_detail = Label.new()
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.add_theme_font_size_override("font_size", 26)
	col.add_child(_detail)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(spacer)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	col.add_child(row)
	_make_button(row, "Menu", func(): _close(); menu_pressed.emit())
	_make_button(row, "Replay", func(): _close(); replay_pressed.emit())
	_next_button = _make_button(row, "Next", func(): _close(); next_pressed.emit())


func _make_button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(150, 90)
	b.add_theme_font_size_override("font_size", 30)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func show_result(level_name: String, stars: int, moves: int, par: int, has_next: bool) -> void:
	_stars = clampi(stars, 0, 3)
	_shown = 0.0
	_time = 0.0
	_title.text = "Level complete!" if stars < 3 else "Perfect!"
	var verdict := "Matched par!" if moves == par else ("Beat par!" if moves < par else "Par is %d. Try for 3 stars?" % par)
	_detail.text = "%s\n%d moves  -  %s" % [level_name, moves, verdict]
	_next_button.text = "Next" if has_next else "Done"
	visible = true
	modulate.a = 0.0
	var t := create_tween()
	t.tween_property(self, "modulate:a", 1.0, 0.2)
	# Pop the stars in one at a time.
	for i in _stars:
		t.tween_property(self, "_shown", float(i + 1), 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_callback(func():
			Sfx.play("star")
			Sfx.vibrate(15))


func _close() -> void:
	visible = false


func _process(delta: float) -> void:
	if visible:
		_time += delta
		_star_area.queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.55))


class _StarArea extends Control:
	var panel: Control

	func _draw() -> void:
		var c := Vector2(size.x / 2.0, size.y * 0.62)
		# Mascot peeking above the stars.
		if panel.mascot_texture:
			var h := size.y * 0.55
			var bob := -absf(sin(panel._time * 6.0)) * 10.0
			var w: float = h * panel.mascot_texture.get_width() / maxf(1.0, float(panel.mascot_texture.get_height()))
			draw_texture_rect(panel.mascot_texture, Rect2(Vector2(c.x - w / 2.0, bob), Vector2(w, h)), false)
		for k in 3:
			var center := c + Vector2((k - 1) * 120.0, 30.0 if k != 1 else 0.0)
			var r := 52.0 if k == 1 else 42.0
			var empty := Fx.star_points(center, r)
			var outline := empty.duplicate()
			outline.append(empty[0])
			draw_colored_polygon(empty, Color(1, 1, 1, 0.08))
			draw_polyline(outline, Color(1, 1, 1, 0.3), 3.0, true)
			var grow := clampf(panel._shown - k, 0.0, 1.2)
			var star_r := r * minf(grow, 1.0) * (1.0 + 0.15 * maxf(0.0, grow - 1.0))
			if star_r >= 3.0:
				var pts := Fx.star_points(center, star_r)
				draw_colored_polygon(pts, Color("#ffd60a"))
