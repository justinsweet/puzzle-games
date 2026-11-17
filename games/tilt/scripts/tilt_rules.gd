extends RefCounted
## Tilt game rules and solver. Must match tools/levelgen/tilt_levelgen.py exactly
## (see the rules list at the top of that file).
##
## A marble is a Dictionary {"pos": Vector2i, "color": String}.
## Holes: Dictionary Vector2i -> color (open holes only). Broken: Dictionary Vector2i -> true.

const DIRS := {
	"U": Vector2i(0, -1),
	"D": Vector2i(0, 1),
	"L": Vector2i(-1, 0),
	"R": Vector2i(1, 0),
}


static func _cells(list) -> Dictionary:
	var out := {}
	if list == null:
		return out
	for p in list:
		out[Vector2i(int(p[0]), int(p[1]))] = p[2] if p.size() > 2 else true
	return out


## Turns a level from levels.json into a Dictionary the game uses.
static func parse(level: Dictionary) -> Dictionary:
	var rows: Array = level["rows"]
	var walls := {}
	var holes := {}
	var marbles := []
	var pads := {}
	for y in rows.size():
		var row: String = rows[y]
		for x in row.length():
			var c: String = row[x]
			if c == "#":
				walls[Vector2i(x, y)] = true
			elif c >= "a" and c <= "z":
				marbles.append({"pos": Vector2i(x, y), "color": c})
			elif c >= "A" and c <= "Z":
				holes[Vector2i(x, y)] = c.to_lower()
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
	var arrows := {}
	var arrow_list = level.get("arrows", [])
	for a in arrow_list:
		arrows[Vector2i(int(a[0]), int(a[1]))] = DIRS[a[2]]
	return {
		"w": (rows[0] as String).length(),
		"h": rows.size(),
		"walls": walls,
		"holes": holes,
		"marbles": marbles,
		"portals": portals,
		"portal_ids": portal_ids,
		"mud": _cells(level.get("mud", [])),
		"arrows": arrows,
		"paint": _cells(level.get("paint", [])),
		"cracked": _cells(level.get("cracked", [])),
		"buttons": _cells(level.get("buttons", [])),
		"gates": _cells(level.get("gates", [])),
	}


static func gates_open(lvl: Dictionary, marbles: Array) -> bool:
	for m in marbles:
		if lvl["buttons"].has(m["pos"]):
			return true
	return false


## Applies one swipe. Returns {"marbles": [...], "holes": {...}, "broken": {...}} where each
## result marble (same order as the input) has "pos", "color", "from", "dropped", "path"
## (cells passed through; null marks a teleport jump), "from_color" and "recolor_at"
## (how many cells along the path its color last changed, or -1).
static func slide(lvl: Dictionary, marbles: Array, holes: Dictionary, broken: Dictionary, dir: String) -> Dictionary:
	var w: int = lvl["w"]
	var h: int = lvl["h"]
	var walls: Dictionary = lvl["walls"]
	var portals: Dictionary = lvl["portals"]
	var cracked: Dictionary = lvl["cracked"]
	var gates: Dictionary = lvl["gates"]
	var arrows: Dictionary = lvl["arrows"]
	var paint: Dictionary = lvl["paint"]
	var mud: Dictionary = lvl["mud"]
	var d: Vector2i = DIRS[dir]
	var order: Array = range(marbles.size())
	order.sort_custom(func(a, b):
		var pa: Vector2i = marbles[a]["pos"]
		var pb: Vector2i = marbles[b]["pos"]
		var la := pa.x * d.x + pa.y * d.y
		var lb := pb.x * d.x + pb.y * d.y
		if la != lb:
			return la > lb
		if pa.x != pb.x:
			return pa.x < pb.x
		return pa.y < pb.y)
	var occupied := {}
	for m in marbles:
		occupied[m["pos"]] = true
	var open_gates := gates_open(lvl, marbles)
	var open_holes := holes.duplicate()
	var hits := {}
	var result := []
	result.resize(marbles.size())
	for i in order:
		var m: Dictionary = marbles[i]
		var p: Vector2i = m["pos"]
		var c: String = m["color"]
		occupied.erase(p)
		var dropped := false
		var used := {}
		var path := [p]
		var steps := 0
		var recolor_at := -1
		while true:
			var n := p + d
			if n.x < 0 or n.y < 0 or n.x >= w or n.y >= h or walls.has(n) or occupied.has(n):
				break
			if cracked.has(n) and not broken.has(n):
				hits[n] = true
				break
			if gates.has(n) and not open_gates:
				break
			if arrows.has(n) and arrows[n] != d:
				break
			if portals.has(n):
				if used.has(n) or occupied.has(portals[n]):
					break
				used[n] = true
				path.append(n)
				path.append(null)  # teleport: jump to the linked pad
				p = portals[n]
			else:
				p = n
			steps += 1
			path.append(p)
			if paint.has(p) and paint[p] != c:
				c = paint[p]
				recolor_at = steps
			if open_holes.get(p, "") == c:
				open_holes.erase(p)
				dropped = true
				break
			if mud.has(p):
				break
		if not dropped:
			occupied[p] = true
		result[i] = {"pos": p, "color": c, "from": m["pos"], "from_color": m["color"],
			"dropped": dropped, "path": path, "recolor_at": recolor_at}
	var new_broken := broken.duplicate()
	for k in hits:
		new_broken[k] = true
	return {"marbles": result, "holes": open_holes, "broken": new_broken}


## Fewest-moves solution from this position, as an Array of "U"/"D"/"L"/"R".
## Returns an empty Array if already solved or if no solution is found.
static func solve(lvl: Dictionary, marbles: Array, holes: Dictionary, broken: Dictionary, max_states: int = 100000) -> Array:
	if marbles.is_empty():
		return []
	var start_key := state_key(marbles, holes, broken)
	var prev := {start_key: null}
	var queue := [{"m": marbles, "h": holes, "b": broken, "k": start_key}]
	var head := 0
	while head < queue.size() and prev.size() < max_states:
		var s: Dictionary = queue[head]
		head += 1
		for dir in ["U", "L", "D", "R"]:
			var r := slide(lvl, s["m"], s["h"], s["b"], dir)
			var alive := []
			for m in r["marbles"]:
				if not m["dropped"]:
					alive.append({"pos": m["pos"], "color": m["color"]})
			var k := state_key(alive, r["holes"], r["broken"])
			if prev.has(k):
				continue
			prev[k] = [s["k"], dir]
			if alive.is_empty():
				var path := []
				var cur = k
				while prev[cur] != null:
					path.push_front(prev[cur][1])
					cur = prev[cur][0]
				return path
			queue.append({"m": alive, "h": r["holes"], "b": r["broken"], "k": k})
	return []


static func state_key(marbles: Array, holes: Dictionary, broken: Dictionary) -> String:
	var parts := PackedStringArray()
	for m in marbles:
		var p: Vector2i = m["pos"]
		parts.append("%d,%d%s" % [p.x, p.y, m["color"]])
	parts.sort()
	var hp := PackedStringArray()
	for p in holes:
		hp.append("%d,%d" % [p.x, p.y])
	hp.sort()
	var bp := PackedStringArray()
	for p in broken:
		bp.append("%d,%d" % [p.x, p.y])
	bp.sort()
	return ";".join(parts) + "|" + ";".join(hp) + "|" + ";".join(bp)
