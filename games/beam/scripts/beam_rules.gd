extends RefCounted
## Beam game rules and solver. Must match tools/levelgen/beam_levelgen.py exactly.

const DIRS := {
	"U": Vector2i(0, -1),
	"D": Vector2i(0, 1),
	"L": Vector2i(-1, 0),
	"R": Vector2i(1, 0),
}


## Turns a level from levels.json into a Dictionary the game uses.
static func parse(level: Dictionary) -> Dictionary:
	var rows: Array = level["rows"]
	var walls := {}
	var mirrors := {}
	for y in rows.size():
		var row: String = rows[y]
		for x in row.length():
			var c: String = row[x]
			if c == "#":
				walls[Vector2i(x, y)] = true
			elif c == "/" or c == "\\":
				mirrors[Vector2i(x, y)] = c
	var emitters := []
	for e in level["emitters"]:
		emitters.append({"pos": Vector2i(int(e["x"]), int(e["y"])), "dir": DIRS[e["dir"]], "color": e["color"]})
	var targets := {}
	for t in level["targets"]:
		targets[Vector2i(int(t["x"]), int(t["y"]))] = t["color"]
	return {
		"w": (rows[0] as String).length(),
		"h": rows.size(),
		"walls": walls,
		"mirrors": mirrors,
		"emitters": emitters,
		"targets": targets,
	}


static func reflect(d: Vector2i, mirror: String) -> Vector2i:
	return Vector2i(-d.y, -d.x) if mirror == "/" else Vector2i(d.y, d.x)


## Follows every beam. Returns {"lit": {pos: true}, "beams": [{"color", "cells": [Vector2i], "end_dir": Vector2i}]}.
static func trace(lvl: Dictionary, mirrors: Dictionary) -> Dictionary:
	var w: int = lvl["w"]
	var h: int = lvl["h"]
	var walls: Dictionary = lvl["walls"]
	var targets: Dictionary = lvl["targets"]
	var blockers := {}
	for e in lvl["emitters"]:
		blockers[e["pos"]] = true
	var lit := {}
	var beams := []
	for e in lvl["emitters"]:
		var p: Vector2i = e["pos"]
		var d: Vector2i = e["dir"]
		var color: String = e["color"]
		var cells := []
		var seen := {}
		while true:
			var n := p + d
			if n.x < 0 or n.y < 0 or n.x >= w or n.y >= h or walls.has(n) or blockers.has(n):
				break
			p = n
			var key := Vector4i(p.x, p.y, d.x, d.y)
			if seen.has(key):
				break
			seen[key] = true
			cells.append(p)
			if targets.has(p):
				if targets[p] == color:
					lit[p] = true
				break
			if mirrors.has(p):
				d = reflect(d, mirrors[p])
		beams.append({"color": color, "start": e["pos"], "start_dir": e["dir"], "cells": cells, "end_dir": d})
	return {"lit": lit, "beams": beams}


static func is_solved(lvl: Dictionary, mirrors: Dictionary) -> bool:
	return trace(lvl, mirrors)["lit"].size() == lvl["targets"].size()


## Fewest taps from this mirror setting to a solved one (Array of Vector2i mirror cells).
## Returns an empty Array if already solved or if no solution exists.
static func solve(lvl: Dictionary, mirrors: Dictionary) -> Array:
	var keys: Array = mirrors.keys()
	keys.sort()
	var n := keys.size()
	var best: Array = []
	var found := false
	for mask in range(1 << n):
		var setting := {}
		var taps := []
		for i in n:
			var flip := ((mask >> i) & 1) == 1
			var m: String = mirrors[keys[i]]
			setting[keys[i]] = (("\\" if m == "/" else "/") if flip else m)
			if flip:
				taps.append(keys[i])
		if (not found or taps.size() < best.size()) and is_solved(lvl, setting):
			best = taps
			found = true
	return best
