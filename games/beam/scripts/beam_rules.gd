extends RefCounted
## Beam game rules and solver. Must match tools/levelgen/beam_levelgen.py exactly.
##
## Colors are bit sets that mix like paint: r=1, y=2, b=4, o=r+y, g=y+b, p=r+b, w=all.

const DIRS := {
	"U": Vector2i(0, -1),
	"D": Vector2i(0, 1),
	"L": Vector2i(-1, 0),
	"R": Vector2i(1, 0),
}
const BITS := {"r": 1, "y": 2, "b": 4, "o": 3, "g": 6, "p": 5, "w": 7}
const NAMES := {1: "r", 2: "y", 4: "b", 3: "o", 6: "g", 5: "p", 7: "w"}


static func _cell(d: Dictionary) -> Vector2i:
	return Vector2i(int(d["x"]), int(d["y"]))


## Turns a level from levels.json into a Dictionary the game uses.
## "fixed" holds mirrors that stay put; "movers" is an Array of {"pos", "m"} the player can drag.
static func parse(level: Dictionary) -> Dictionary:
	var rows: Array = level["rows"]
	var walls := {}
	var fixed := {}
	var pads := {}
	for y in rows.size():
		var row: String = rows[y]
		for x in row.length():
			var c: String = row[x]
			if c == "#":
				walls[Vector2i(x, y)] = true
			elif c == "/" or c == "\\":
				fixed[Vector2i(x, y)] = c
			elif c >= "0" and c <= "9":
				if not pads.has(c):
					pads[c] = []
				pads[c].append(Vector2i(x, y))
	var portals := {}
	var portal_ids := {}
	for id in pads:
		var cells: Array = pads[id]
		if cells.size() == 2:
			portals[cells[0]] = cells[1]
			portals[cells[1]] = cells[0]
			portal_ids[cells[0]] = id
			portal_ids[cells[1]] = id
	var emitters := []
	for e in level["emitters"]:
		emitters.append({"pos": _cell(e), "dir": DIRS[e["dir"]], "color": BITS[e["color"]]})
	var targets := {}
	for t in level["targets"]:
		targets[_cell(t)] = BITS[t["color"]]
	var filters := {}
	for f in level.get("filters", []):
		filters[_cell(f)] = BITS[f["color"]]
	var tints := {}
	for t in level.get("tints", []):
		tints[_cell(t)] = BITS[t["color"]]
	var movers := []
	for m in level.get("movers", []):
		movers.append({"pos": _cell(m), "m": m["m"]})
	var goal_fixed := {}
	var goal_movers := []
	if level.has("goal"):
		for k in level["goal"]["mirrors"]:
			var parts: PackedStringArray = (k as String).split(",")
			goal_fixed[Vector2i(int(parts[0]), int(parts[1]))] = level["goal"]["mirrors"][k]
		for m in level["goal"]["movers"]:
			goal_movers.append({"pos": _cell(m), "m": m["m"]})
	return {
		"w": (rows[0] as String).length(),
		"h": rows.size(),
		"walls": walls,
		"fixed": fixed,
		"movers": movers,
		"portals": portals,
		"portal_ids": portal_ids,
		"emitters": emitters,
		"targets": targets,
		"filters": filters,
		"tints": tints,
		"goal_fixed": goal_fixed,
		"goal_movers": goal_movers,
	}


static func reflect(d: Vector2i, mirror: String) -> Vector2i:
	return Vector2i(-d.y, -d.x) if mirror == "/" else Vector2i(d.y, d.x)


## All mirrors on the board right now (fixed + movers) as Vector2i -> "/" or "\\".
static func mirror_map(fixed: Dictionary, movers: Array) -> Dictionary:
	var all := fixed.duplicate()
	for m in movers:
		all[m["pos"]] = m["m"]
	return all


## Follows every beam. Returns {"lit": {pos: true}, "beams": [beam]} where a beam is
## {"start": Vector2i, "segments": [{"color": int, "cells": [Vector2i]}], "end_dir": Vector2i, "stopped_at_target": bool}.
## A new segment starts when the beam changes color or comes out of a portal.
static func trace(lvl: Dictionary, mirrors: Dictionary) -> Dictionary:
	var w: int = lvl["w"]
	var h: int = lvl["h"]
	var walls: Dictionary = lvl["walls"]
	var targets: Dictionary = lvl["targets"]
	var filters: Dictionary = lvl["filters"]
	var tints: Dictionary = lvl["tints"]
	var portals: Dictionary = lvl["portals"]
	var blockers := {}
	for e in lvl["emitters"]:
		blockers[e["pos"]] = true
	var lit := {}
	var beams := []
	for e in lvl["emitters"]:
		var p: Vector2i = e["pos"]
		var d: Vector2i = e["dir"]
		var c: int = e["color"]
		var segments := [{"color": c, "cells": [p]}]
		var seen := {}
		var at_target := false
		while true:
			var n := p + d
			if n.x < 0 or n.y < 0 or n.x >= w or n.y >= h or walls.has(n) or blockers.has(n):
				break
			p = n
			var key := "%d,%d,%d,%d,%d" % [p.x, p.y, d.x, d.y, c]
			if seen.has(key):
				break
			seen[key] = true
			segments[-1]["cells"].append(p)
			if targets.has(p):
				if targets[p] == c:
					lit[p] = true
				at_target = true
				break
			if filters.has(p) and filters[p] != c:
				at_target = true  # beam ends inside the filter
				break
			if tints.has(p) and (c | tints[p]) != c:
				c = c | tints[p]
				segments.append({"color": c, "cells": [p]})
			if portals.has(p):
				p = portals[p]
				segments.append({"color": c, "cells": [p]})
			if mirrors.has(p):
				d = reflect(d, mirrors[p])
		beams.append({"start": e["pos"], "segments": segments, "end_dir": d, "stopped_at_target": at_target})
	return {"lit": lit, "beams": beams}


static func is_solved(lvl: Dictionary, mirrors: Dictionary) -> bool:
	return trace(lvl, mirrors)["lit"].size() == lvl["targets"].size()


## Fewest flips of the fixed mirrors that solve the board with movers where they are.
## Returns an Array of Vector2i to flip, or null if none works.
static func solve_flips(lvl: Dictionary, fixed: Dictionary, movers: Array) -> Variant:
	var keys: Array = fixed.keys()
	var n := keys.size()
	var best = null
	for mask in range(1 << n):
		var setting := {}
		var taps := []
		for i in n:
			var flip := ((mask >> i) & 1) == 1
			var m: String = fixed[keys[i]]
			setting[keys[i]] = (("\\" if m == "/" else "/") if flip else m)
			if flip:
				taps.append(keys[i])
		if best != null and taps.size() >= best.size():
			continue
		if is_solved(lvl, mirror_map(setting, movers)):
			best = taps
	return best


## The next step toward a solution: {"kind": "flip", "cell"} or {"kind": "drag", "from", "to"}.
## Returns {} if already solved or stuck.
static func next_hint(lvl: Dictionary, fixed: Dictionary, movers: Array) -> Dictionary:
	if is_solved(lvl, mirror_map(fixed, movers)):
		return {}
	var flips = solve_flips(lvl, fixed, movers)
	if flips != null and not flips.is_empty():
		return {"kind": "flip", "cell": flips[0], "left": flips.size()}
	# Movers need to go somewhere else: guide them toward the stored goal.
	var goal_movers: Array = lvl["goal_movers"]
	var on_goal := {}
	for g in goal_movers:
		for m in movers:
			if m["pos"] == g["pos"]:
				on_goal[g["pos"]] = m
	for g in goal_movers:
		if not on_goal.has(g["pos"]):
			for m in movers:
				var placed := false
				for g2 in goal_movers:
					if m["pos"] == g2["pos"]:
						placed = true
				if not placed:
					return {"kind": "drag", "from": m["pos"], "to": g["pos"]}
	for g in goal_movers:
		var m: Dictionary = on_goal[g["pos"]]
		if m["m"] != g["m"]:
			return {"kind": "flip", "cell": m["pos"], "left": 1}
	var goal_fixed: Dictionary = lvl["goal_fixed"]
	for p in fixed:
		if goal_fixed.has(p) and fixed[p] != goal_fixed[p]:
			return {"kind": "flip", "cell": p, "left": 1}
	return {}
