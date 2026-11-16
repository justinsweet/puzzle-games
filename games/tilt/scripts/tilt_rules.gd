extends RefCounted
## Tilt game rules and solver. Must match tools/levelgen/tilt_levelgen.py exactly.
##
## A marble is a Dictionary {"pos": Vector2i, "color": String}.
## Holes are a Dictionary Vector2i -> color String (open holes only).

const DIRS := {
	"U": Vector2i(0, -1),
	"D": Vector2i(0, 1),
	"L": Vector2i(-1, 0),
	"R": Vector2i(1, 0),
}


## Turns level rows ("#", ".", lowercase marble, uppercase hole) into a level Dictionary.
static func parse(rows: Array) -> Dictionary:
	var walls := {}
	var holes := {}
	var marbles := []
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
	return {
		"w": (rows[0] as String).length(),
		"h": rows.size(),
		"walls": walls,
		"holes": holes,
		"marbles": marbles,
	}


## Applies one swipe. Returns {"marbles": [...], "holes": {...}} where each result
## marble (same order as the input) has "pos", "color", "from" and "dropped".
static func slide(w: int, h: int, walls: Dictionary, marbles: Array, holes: Dictionary, dir: String) -> Dictionary:
	var d: Vector2i = DIRS[dir]
	var order: Array = range(marbles.size())
	# Leading edge first: the marble furthest along the swipe direction moves first.
	order.sort_custom(func(a, b):
		var pa: Vector2i = marbles[a]["pos"]
		var pb: Vector2i = marbles[b]["pos"]
		return pa.x * d.x + pa.y * d.y > pb.x * d.x + pb.y * d.y)
	var occupied := {}
	for m in marbles:
		occupied[m["pos"]] = true
	var open_holes := holes.duplicate()
	var result := []
	result.resize(marbles.size())
	for i in order:
		var m: Dictionary = marbles[i]
		var p: Vector2i = m["pos"]
		occupied.erase(p)
		var dropped := false
		while true:
			var n := p + d
			if n.x < 0 or n.y < 0 or n.x >= w or n.y >= h or walls.has(n) or occupied.has(n):
				break
			p = n
			if open_holes.get(p, "") == m["color"]:
				open_holes.erase(p)
				dropped = true
				break
		if not dropped:
			occupied[p] = true
		result[i] = {"pos": p, "color": m["color"], "from": m["pos"], "dropped": dropped}
	return {"marbles": result, "holes": open_holes}


## Fewest-moves solution from this position, as an Array of "U"/"D"/"L"/"R".
## Returns an empty Array if already solved or if no solution is found.
static func solve(w: int, h: int, walls: Dictionary, marbles: Array, holes: Dictionary, max_states: int = 100000) -> Array:
	if marbles.is_empty():
		return []
	var start_key := state_key(marbles, holes)
	var prev := {start_key: null}
	var queue := [{"m": marbles, "h": holes, "k": start_key}]
	var head := 0
	while head < queue.size() and prev.size() < max_states:
		var s: Dictionary = queue[head]
		head += 1
		for dir in ["U", "L", "D", "R"]:
			var r := slide(w, h, walls, s["m"], s["h"], dir)
			var alive := []
			for m in r["marbles"]:
				if not m["dropped"]:
					alive.append({"pos": m["pos"], "color": m["color"]})
			var k := state_key(alive, r["holes"])
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
			queue.append({"m": alive, "h": r["holes"], "k": k})
	return []


static func state_key(marbles: Array, holes: Dictionary) -> String:
	var parts := PackedStringArray()
	for m in marbles:
		var p: Vector2i = m["pos"]
		parts.append("%d,%d%s" % [p.x, p.y, m["color"]])
	parts.sort()
	var hp := PackedStringArray()
	for p in holes:
		hp.append("%d,%d" % [p.x, p.y])
	hp.sort()
	return ";".join(parts) + "|" + ";".join(hp)
