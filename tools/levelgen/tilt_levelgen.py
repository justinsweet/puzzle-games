#!/usr/bin/env python3
"""Tilt level generator and solver.

Level format (JSON). "rows" is a list of equal-length strings:
  '#' wall   '.' floor
  lowercase letter (r g b y p) = marble of that color (a color can have several marbles)
  uppercase letter (R G B Y P) = hole of that color
  digit 1-4 = teleport pad; the two pads with the same digit are linked
Optional extra pieces, each a list of [x, y] (or [x, y, value]):
  "mud":     [[x, y]]            a marble that rolls onto mud stops there
  "arrows":  [[x, y, "U|D|L|R"]] one-way gate: can only be entered moving that way
  "paint":   [[x, y, "r"]]       paint pad: a marble rolling over it turns that color
  "cracked": [[x, y]]            cracked wall: blocks once, then breaks after that swipe
  "buttons": [[x, y]]            while any marble rests on a button, all gates are open
  "gates":   [[x, y]]            closed gates block like walls

Rules (must match games/tilt/scripts/tilt_rules.gd exactly):
  * A swipe moves every marble that way, leading edge first; ties go to the
    smaller x, then the smaller y.
  * Gates are open for the whole swipe if a marble rests on a button when the swipe starts.
  * A marble slides until the next cell is outside the board, a wall, a marble, an
    unbroken cracked wall (which then breaks after the swipe), a closed gate, or a
    one-way gate pointing another way.
  * Teleport pad: the marble comes out of the linked pad and keeps sliding. If the
    linked pad is occupied it stops before the pad. Each pad works once per swipe.
  * After entering a cell: a paint pad recolors the marble; then an open hole of the
    marble's color swallows it (the hole is filled); then mud stops it.
  * The level is solved when no marbles are left.
"""
import argparse
import json
import os
import random
from collections import deque

DIRS = {"U": (0, -1), "D": (0, 1), "L": (-1, 0), "R": (1, 0)}
COLORS = "rgbyp"


class Level:
    def __init__(self, data):
        rows = data["rows"]
        self.rows = rows
        self.w, self.h = len(rows[0]), len(rows)
        self.walls, self.holes, self.marbles, pads = set(), {}, [], {}
        for y, row in enumerate(rows):
            for x, c in enumerate(row):
                if c == "#":
                    self.walls.add((x, y))
                elif c.islower():
                    self.marbles.append((x, y, c))
                elif c.isupper():
                    self.holes[(x, y)] = c.lower()
                elif c.isdigit():
                    pads.setdefault(c, []).append((x, y))
        self.portals = {}
        for cells in pads.values():
            if len(cells) == 2:
                self.portals[cells[0]] = cells[1]
                self.portals[cells[1]] = cells[0]
        self.mud = {tuple(p[:2]) for p in data.get("mud", [])}
        self.arrows = {tuple(p[:2]): DIRS[p[2]] for p in data.get("arrows", [])}
        self.paint = {tuple(p[:2]): p[2] for p in data.get("paint", [])}
        self.cracked = {tuple(p[:2]) for p in data.get("cracked", [])}
        self.buttons = {tuple(p[:2]) for p in data.get("buttons", [])}
        self.gates = {tuple(p[:2]) for p in data.get("gates", [])}

    def slide(self, marbles, holes, broken, d, stats=None):
        dx, dy = DIRS[d]
        order = sorted(marbles, key=lambda m: (-(m[0] * dx + m[1] * dy), m[0], m[1]))
        occupied = {(m[0], m[1]) for m in marbles}
        gates_open = any((m[0], m[1]) in self.buttons for m in marbles)
        open_h = dict(holes)
        hits = set()
        out = []
        for (x, y, c) in order:
            occupied.discard((x, y))
            dropped = False
            used = set()
            while True:
                n = (x + dx, y + dy)
                if n[0] < 0 or n[1] < 0 or n[0] >= self.w or n[1] >= self.h or n in self.walls or n in occupied:
                    break
                if n in self.cracked and n not in broken:
                    hits.add(n)
                    break
                if n in self.gates and not gates_open:
                    break
                if n in self.arrows and self.arrows[n] != (dx, dy):
                    break
                if n in self.portals:
                    if n in used or self.portals[n] in occupied:
                        break
                    used.add(n)
                    x, y = self.portals[n]
                    if stats is not None:
                        stats["teleports"] += 1
                else:
                    x, y = n
                    if stats is not None:
                        if n in self.arrows:
                            stats["arrows"] += 1
                        if n in self.gates:
                            stats["gates"] += 1
                p = (x, y)
                if p in self.paint and self.paint[p] != c:
                    c = self.paint[p]
                    if stats is not None:
                        stats["paint"] += 1
                if open_h.get(p) == c:
                    del open_h[p]
                    dropped = True
                    break
                if p in self.mud:
                    if stats is not None:
                        stats["mud"] += 1
                    break
            if not dropped:
                occupied.add((x, y))
                out.append((x, y, c))
        if stats is not None:
            stats["breaks"] += len(hits)
        return tuple(sorted(out)), open_h, broken | frozenset(hits)

    def solve(self, max_states=300_000):
        """Breadth-first search. Returns (path_string or None, states_explored)."""
        start_m = tuple(sorted(self.marbles))
        if not start_m:
            return "", 1
        start = (start_m, tuple(sorted(self.holes.items())), frozenset())
        prev = {start: None}
        queue = deque([(start_m, self.holes, frozenset())])
        while queue and len(prev) < max_states:
            m, hl, br = queue.popleft()
            k0 = (m, tuple(sorted(hl.items())), br)
            for d in "ULDR":
                nm, nh, nb = self.slide(m, hl, br, d)
                k = (nm, tuple(sorted(nh.items())), nb)
                if k in prev:
                    continue
                prev[k] = (k0, d)
                if not nm:
                    path = []
                    cur = k
                    while prev[cur] is not None:
                        cur, step = prev[cur]
                        path.append(step)
                    return "".join(reversed(path)), len(prev)
                queue.append((nm, nh, nb))
        return None, len(prev)

    def replay_stats(self, path):
        stats = {k: 0 for k in ("teleports", "arrows", "gates", "paint", "mud", "breaks")}
        m, hl, br = tuple(sorted(self.marbles)), self.holes, frozenset()
        for d in path:
            m, hl, br = self.slide(m, hl, br, d, stats)
        return stats


def random_level(rng, size, per_color, spec):
    w = h = size + 2
    grid = [["#" if x in (0, w - 1) or y in (0, h - 1) else "." for x in range(w)] for y in range(h)]
    interior = [(x, y) for y in range(1, h - 1) for x in range(1, w - 1)]
    rng.shuffle(interior)
    n_walls = int(len(interior) * spec.get("walls", 0.12))
    walls = interior[:n_walls]
    free = interior[n_walls:]
    extra = {}
    n_cracked = spec.get("cracked", 0)
    if n_cracked:
        extra["cracked"] = [list(p) for p in walls[:n_cracked]]
        walls = walls[n_cracked:]
    for (x, y) in walls:
        grid[y][x] = "#"
    for i in range(spec.get("portals", 0)):
        for _ in range(2):
            x, y = free.pop()
            grid[y][x] = str(i + 1)
    if spec.get("mud"):
        extra["mud"] = [list(free.pop()) for _ in range(spec["mud"])]
    if spec.get("arrows"):
        extra["arrows"] = [list(free.pop()) + [rng.choice("UDLR")] for _ in range(spec["arrows"])]
    if spec.get("buttons"):
        extra["buttons"] = [list(free.pop()) for _ in range(spec["buttons"])]
        extra["gates"] = [list(free.pop()) for _ in range(spec.get("gates", 1))]
    hole_colors = []
    for i, count in enumerate(per_color):
        hole_colors += [COLORS[i]] * count
    marble_colors = list(hole_colors)
    if spec.get("paint"):
        # Some marbles start the "wrong" color; paint pads of the needed colors fix them.
        used = sorted(set(hole_colors))
        spare = [c for c in COLORS[: max(len(per_color) + 1, 2)]]
        n_wrong = max(1, int(len(marble_colors) * 0.6))
        for i in rng.sample(range(len(marble_colors)), min(n_wrong, len(marble_colors))):
            marble_colors[i] = rng.choice([c for c in spare if c != marble_colors[i]])
        need = list(used)
        rng.shuffle(need)
        extra["paint"] = [list(free.pop()) + [need[i % len(need)]] for i in range(spec["paint"])]
    for c in marble_colors:
        x, y = free.pop()
        grid[y][x] = c
    for c in hole_colors:
        x, y = free.pop()
        grid[y][x] = c.upper()
    return {"rows": ["".join(r) for r in grid], **extra}


def W(name, intro, curve, needs=None):
    return {"name": name, "intro": intro, "curve": curve, "needs": needs}


def C(size, per_color, lo, hi, **spec):
    return (size, per_color, lo, hi, spec)


# Each world adds one idea. Difficulty rises inside each world.
WORLDS = [
    W("Meadow", "Swipe to tilt. Every marble slides until it hits something.", None),
    W("Pond", "Some colors have more than one marble. Fill every hole.", None),
    W("Portal Grove", "Teleport pads send a marble to the matching pad.", None),
    W("Mud Marsh", "Mud stops a marble in its tracks.", [
        C(5, [1], 2, 4, mud=1), C(5, [1], 3, 5, mud=2), C(5, [1, 1], 3, 5, mud=1),
        C(6, [1], 4, 6, mud=2), C(6, [1, 1], 4, 6, mud=2), C(6, [2], 5, 7, mud=2),
        C(6, [1, 1], 5, 7, mud=3), C(6, [2, 1], 6, 8, mud=2), C(7, [1, 1], 6, 9, mud=3),
        C(7, [2, 1], 6, 9, mud=3), C(7, [1, 1, 1], 7, 10, mud=3), C(7, [2, 2], 8, 12, mud=3),
    ], needs="mud"),
    W("Orchard Gates", "One-way gates only let marbles through in the arrow's direction.", [
        C(5, [1], 2, 4, arrows=1), C(5, [1], 3, 5, arrows=2), C(5, [1, 1], 3, 5, arrows=2),
        C(6, [1], 4, 6, arrows=3), C(6, [1, 1], 4, 6, arrows=2), C(6, [2], 5, 7, arrows=3),
        C(6, [1, 1], 5, 7, arrows=3, mud=1), C(6, [2, 1], 6, 8, arrows=3), C(7, [1, 1], 6, 9, arrows=4),
        C(7, [2, 1], 6, 9, arrows=4, portals=1), C(7, [1, 1, 1], 7, 10, arrows=4), C(7, [2, 2], 8, 12, arrows=5, mud=1),
    ], needs="arrows"),
    W("Paint Barn", "Paint pads change a marble's color as it rolls over them.", [
        C(5, [1], 2, 4, paint=1), C(5, [1], 3, 5, paint=1), C(5, [1, 1], 3, 5, paint=2),
        C(6, [1, 1], 4, 6, paint=2), C(6, [2], 4, 6, paint=1), C(6, [1, 1], 5, 7, paint=2),
        C(6, [2, 1], 5, 7, paint=2), C(6, [1, 1, 1], 6, 8, paint=3), C(7, [2, 1], 6, 9, paint=2, mud=1),
        C(7, [1, 1, 1], 6, 9, paint=3), C(7, [2, 2], 7, 10, paint=3), C(7, [2, 1, 1], 8, 12, paint=3, arrows=2),
    ], needs="paint"),
    W("Crumbling Quarry", "Cracked walls break after one bump. Use them wisely.", [
        C(5, [1], 2, 4, cracked=1), C(5, [1], 3, 5, cracked=2), C(5, [1, 1], 3, 5, cracked=2),
        C(6, [1], 4, 6, cracked=3), C(6, [1, 1], 4, 6, cracked=3), C(6, [2], 5, 7, cracked=3),
        C(6, [1, 1], 5, 7, cracked=4, mud=1), C(6, [2, 1], 6, 8, cracked=4), C(7, [1, 1], 6, 9, cracked=4),
        C(7, [2, 1], 6, 9, cracked=5, arrows=1), C(7, [1, 1, 1], 7, 10, cracked=5), C(7, [2, 2], 8, 12, cracked=6, paint=1),
    ], needs="breaks"),
    W("Clockwork Mill", "While a marble rests on a button, the gates open.", [
        C(5, [1, 1], 3, 5, buttons=1, gates=1), C(5, [1, 1], 3, 6, buttons=1, gates=2), C(6, [1, 1], 4, 6, buttons=1, gates=2),
        C(6, [2], 4, 7, buttons=1, gates=2), C(6, [1, 1], 5, 7, buttons=1, gates=3), C(6, [2, 1], 5, 8, buttons=1, gates=2),
        C(6, [1, 1, 1], 6, 8, buttons=1, gates=3), C(7, [2, 1], 6, 9, buttons=1, gates=3, mud=1), C(7, [1, 1], 6, 9, buttons=2, gates=3),
        C(7, [2, 1], 7, 10, buttons=1, gates=4, arrows=1), C(7, [1, 1, 1], 7, 11, buttons=2, gates=4), C(7, [2, 2], 8, 12, buttons=2, gates=4, paint=1),
    ], needs="gates"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--tries", type=int, default=2500)
    ap.add_argument("--regenerate-all", action="store_true",
                    help="also regenerate worlds that already exist in --out (changes existing levels!)")
    args = ap.parse_args()
    existing = {}
    if os.path.exists(args.out) and not args.regenerate_all:
        for w in json.load(open(args.out))["worlds"]:
            existing[w["name"]] = w
    worlds_out, n = [], 0
    for wi, world in enumerate(WORLDS):
        if world["name"] in existing:
            w = existing[world["name"]]
            for lv in w["levels"]:
                n += 1
                lv["id"] = n
            worlds_out.append(w)
            print(f"{world['name']:16} kept {len(w['levels'])} existing levels")
            continue
        if world["curve"] is None:
            raise SystemExit(f"{world['name']} has no curve; generate it from an older version or keep it in --out.")
        rng = random.Random(args.seed * 1000 + wi)
        levels = []
        for (size, per_color, lo, hi, spec) in world["curve"]:
            n += 1
            best = None
            marbles = sum(per_color)
            for _ in range(args.tries):
                data = random_level(rng, size, per_color, spec)
                lvl = Level(data)
                path, states = lvl.solve()
                if path is None or not (lo <= len(path) <= hi) or len(set(path)) == 1:
                    continue
                stats = lvl.replay_stats(path)
                if world["needs"] and stats[world["needs"]] == 0:
                    continue
                if spec.get("portals") and stats["teleports"] == 0:
                    continue
                if best is None or states > best[2]:
                    best = (data, path, states)
                if states > 60 * marbles:
                    break
            if best is None:
                raise SystemExit(f"Could not generate level {n} ({world['name']}); loosen its settings.")
            data, path, states = best
            levels.append({"id": n, **data, "par": len(path), "solution": path})
            print(f"{world['name']:16} level {n:2}: {size}x{size}, marbles {per_color}, {spec}, par {len(path):2}, {states} states")
        worlds_out.append({"name": world["name"], "intro": world["intro"], "levels": levels})
    with open(args.out, "w") as f:
        json.dump({"worlds": worlds_out}, f, indent=2)
        f.write("\n")
    print(f"Wrote {n} levels to {args.out}")


if __name__ == "__main__":
    main()
