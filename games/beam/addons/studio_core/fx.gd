extends RefCounted
## Small reusable effects. Use: const Fx := preload("res://addons/studio_core/fx.gd")


## Confetti-style burst of colored particles at a position.
static func burst(parent: Node, pos: Vector2, colors: Array, amount: int = 70) -> void:
	var p := CPUParticles2D.new()
	p.position = pos
	p.one_shot = true
	p.explosiveness = 0.95
	p.amount = amount
	p.lifetime = 1.4
	p.spread = 180.0
	p.direction = Vector2(0, -1)
	p.initial_velocity_min = 300.0
	p.initial_velocity_max = 750.0
	p.gravity = Vector2(0, 1100)
	p.angular_velocity_min = -360.0
	p.angular_velocity_max = 360.0
	p.scale_amount_min = 6.0
	p.scale_amount_max = 12.0
	var offsets := PackedFloat32Array()
	var cols := PackedColorArray()
	for i in colors.size():
		offsets.append(float(i) / max(1, colors.size() - 1))
		cols.append(colors[i])
	if colors.size() == 1:
		offsets.append(1.0)
		cols.append(colors[0])
	var g := Gradient.new()
	g.offsets = offsets
	g.colors = cols
	p.color_initial_ramp = g
	parent.add_child(p)
	p.emitting = true
	parent.get_tree().create_timer(p.lifetime + 0.5).timeout.connect(p.queue_free)


## Quick "pop" of a CanvasItem's scale, e.g. on a win.
static func pop(node: CanvasItem, amount: float = 1.12) -> void:
	if not (node is Node2D or node is Control):
		return
	var t := node.create_tween()
	t.tween_property(node, "scale", Vector2(amount, amount), 0.12).set_trans(Tween.TRANS_BACK)
	t.tween_property(node, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_ELASTIC)


## Star shape centered at c, for drawing star ratings without needing a font glyph.
static func star_points(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 10:
		var radius := r if i % 2 == 0 else r * 0.45
		var a := -PI / 2.0 + i * PI / 5.0
		pts.append(c + Vector2(cos(a), sin(a)) * radius)
	return pts
