extends Control
## The game's mascot during play: shows a pose and reacts to what the player does.
##
## Usage:
##   var m := preload("res://addons/studio_core/mascot_view.gd").new()
##   m.load_poses("res://assets/")   # mascot.png (idle), mascot_cheering.png, ...
##   parent.add_child(m)
##   m.react("cheering")   # or "excited", "thinking", "sleepy"; returns to idle after a moment
## If no mascot art exists, it stays hidden.

const POSES := ["excited", "thinking", "cheering", "sleepy"]
const SLEEP_AFTER := 25.0

var poses := {}
var pose := "idle"
var _time := 0.0
var _since_activity := 0.0
var _hold := 0.0
var _pop := 0.0


func load_poses(folder: String) -> void:
	var idle_path := folder + "mascot.png"
	if ResourceLoader.exists(idle_path):
		poses["idle"] = load(idle_path)
	for p in POSES:
		var path := folder + "mascot_%s.png" % p
		if ResourceLoader.exists(path):
			poses[p] = load(path)
	visible = poses.has("idle")


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Show a pose for a few seconds (or until the next reaction), with a little pop.
func react(new_pose: String, seconds: float = 2.5) -> void:
	_since_activity = 0.0
	if not poses.has(new_pose):
		new_pose = "idle"
	pose = new_pose
	_hold = seconds
	_pop = 1.0
	queue_redraw()


## Call on any player action so the mascot wakes up.
func poke() -> void:
	_since_activity = 0.0
	if pose == "sleepy":
		react("idle", 0.0)


func _process(delta: float) -> void:
	if not visible:
		return
	_time += delta
	_since_activity += delta
	_pop = maxf(0.0, _pop - delta * 3.0)
	if _hold > 0.0:
		_hold -= delta
		if _hold <= 0.0 and pose != "sleepy":
			pose = "idle"
	if pose == "idle" and _since_activity > SLEEP_AFTER and poses.has("sleepy"):
		pose = "sleepy"
	queue_redraw()


func _draw() -> void:
	var tex: Texture2D = poses.get(pose, poses.get("idle"))
	if tex == null:
		return
	var bob := sin(_time * (1.2 if pose == "sleepy" else 2.6)) * size.y * (0.015 if pose == "sleepy" else 0.04)
	if pose == "cheering" or pose == "excited":
		bob = -absf(sin(_time * 7.0)) * size.y * 0.08
	var s := 1.0 + 0.18 * _pop
	var box := Vector2(size.x, size.y) * s
	var pos := (size - box) / 2.0 + Vector2(0, bob)
	draw_texture_rect(tex, Rect2(pos, box), false)
