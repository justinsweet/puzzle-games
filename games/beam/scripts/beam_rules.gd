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
	var links := {}   # cell -> its twin
	for pair in level.get("links", []):
		var a := Vector2i(int(pair[0][0]), int(pair[0][1]))
		var b := Vector2i(int(pair[1][0]), int(pair[1][1]))
		links[a] = b
		links[b] = a
	var shadows := {}
	for p in level.get("shadows", []):
		shadows[Vector2i(int(p[0]), int(p[1]))] = true
	var prisms := {}
	for p in level.get("prisms", []):
		prisms[Vector2i(int(p[0]), int(p[1]))] = true
	var gates := {}
	for g in level.get("gates", []):
		gates[_cell(g)] = str(g["id"])
	var opens := {}
	for t in level["targets"]:
		if t.has("opens"):
			opens[_cell(t)] = str(t["opens"])
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
		"links": links,
		"shadows": shadows,
		"prisms": prisms,
		"gates": gates,
		"opens": opens,
		"max_bounces": int(level.get("max_bounces", 0)),
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


## One pass over every beam with the given gates open. Returns {"lit": {pos: true},
## "shadow": bool, "beams": [beam]} where a beam is {"start", "segments": [{"color", "cells"}],
## "end_dir", "stopped_at_target"}. A new segment starts when the color changes or the
## beam comes out of a portal. Beams that a prism sends out are added to the list.
static func trace_once(lvl: Dictionary, mirrors: Dictionary, opened: Dictionary) -> Dictionary:
	var w: int = lvl["w"]
	var h: int = lvl["h"]
	var walls: Dictionary = lvl["walls"]
	var targets: Dictionary = lvl["targets"]
	var filters: Dictionary = lvl["filters"]
	var tints: Dictionary = lvl["tints"]
	var portals: Dictionary = lvl["portals"]
	var shadows: Dictionary = lvl["shadows"]
	var prisms: Dictionary = lvl["prisms"]
	var gates: Dictionary = lvl["gates"]
	var max_bounces: int = lvl["max_bounces"]
	var blockers := {}
	for e in lvl["emitters"]:
		blockers[e["pos"]] = true
	var lit := {}
	var shadow := false
	var beams := []
	var queue := []
	for e in lvl["emitters"]:
		queue.append([e["pos"], e["dir"], e["color"]])
	var qi := 0
	while qi < queue.size():
		var item: Array = queue[qi]
		qi += 1
		var start: Vector2i = item[0]
		var p: Vector2i = start
		var d: Vector2i = item[1]
		var c: int = item[2]
		var segments := [{"color": c, "cells": [p]}]
		var seen := {}
		var at_target := false
		var bounces := 0
		while true:
			var n := p + d
			if n.x < 0 or n.y < 0 or n.x >= w or n.y >= h or walls.has(n) or blockers.has(n):
				break
			if gates.has(n) and not opened.has(gates[n]):
				break
			p = n
			var key := "%d,%d,%d,%d,%d" % [p.x, p.y, d.x, d.y, c]
			if seen.has(key):
				break
			seen[key] = true
			segments[-1]["cells"].append(p)
			if shadows.has(p):
				shadow = true
				at_target = true
				break
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
			if prisms.has(p) and c == 7:
				queue.append([p, Vector2i(d.y, -d.x), 1])   # red turns left
				queue.append([p, d, 2])                     # yellow goes straight
				queue.append([p, Vector2i(-d.y, d.x), 4])   # blue turns right
				at_target = true
				break
			if portals.has(p):
				p = portals[p]
				segments.append({"color": c, "cells": [p]})
			if mirrors.has(p):
				if max_bounces > 0 and bounces >= max_bounces:
					at_target = true  # the light fades at this mirror
					break
				d = reflect(d, mirrors[p])
				bounces += 1
		beams.append({"start": start, "segments": segments, "end_dir": d, "stopped_at_target": at_target})
	return {"lit": lit, "shadow": shadow, "beams": beams}


## Traces the board, opening gates for lit crystals until nothing changes (at most 8 passes).
## Also returns "opened": the gate ids that are open.
static func trace(lvl: Dictionary, mirrors: Dictionary) -> Dictionary:
	var opened := {}
	var result := {}
	for i in 8:
		result = trace_once(lvl, mirrors, opened)
		var new_open := {}
		for p in result["lit"]:
			if lvl["opens"].has(p):
				new_open[lvl["opens"][p]] = true
		var same := new_open.size() == opened.size()
		if same:
			for k in new_open:
				if not opened.has(k):
					same = false
		if same:
			break
		opened = new_open
	result["opened"] = opened
	return result


static func is_solved(lvl: Dictionary, mirrors: Dictionary) -> bool:
	var t := trace(lvl, mirrors)
	return t["lit"].size() == lvl["targets"].size() and not t["shadow"]


static func flip(m: String) -> String:
	return "\\" if m == "/" else "/"


## Fixed mirrors grouped so twins flip together.
static func flip_groups(lvl: Dictionary, fixed: Dictionary) -> Array:
	var groups := []
	var done := {}
	var keys: Array = fixed.keys()
	keys.sort()
	for k in keys:
		if done.has(k):
			continue
		if lvl["links"].has(k):
			var twin: Vector2i = lvl["links"][k]
			groups.append([k, twin])
			done[twin] = true
		else:
			groups.append([k])
		done[k] = true
	return groups


## Fewest taps on fixed mirrors (a twin pair is one tap) that solve the board with movers
## where they are. Returns an Array of Vector2i to tap, or null if none works.
static func solve_flips(lvl: Dictionary, fixed: Dictionary, movers: Array) -> Variant:
	var groups := flip_groups(lvl, fixed)
	var n := groups.size()
	var best = null
	for mask in range(1 << n):
		var taps := []
		for i in n:
			if ((mask >> i) & 1) == 1:
				taps.append(groups[i][0])
		if best != null and taps.size() >= best.size():
			continue
		var setting := fixed.duplicate()
		for i in n:
			if ((mask >> i) & 1) == 1:
				for cell in groups[i]:
					setting[cell] = flip(setting[cell])
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
