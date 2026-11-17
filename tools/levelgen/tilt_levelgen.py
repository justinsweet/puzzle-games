#!/usr/bin/env python3
"""Tilt level generator and solver.

Level format: a list of equal-length strings (rows).
  '#' wall   '.' floor
  lowercase letter (r g b y p) = marble of that color (a color can have several marbles)
  uppercase letter (R G B Y P) = hole of that color (one per marble of that color)
  digit 1-4 = teleport pad; the two pads with the same digit are linked

Rules (must match games/tilt/scripts/tilt_rules.gd exactly):
  * A swipe moves every marble in that direction. Marbles are processed
    leading edge first (closest to the wall they are moving toward).
  * A marble slides until the next cell is a wall, outside the board,
    or another marble.
  * Teleport pads: a marble that slides onto a pad comes out on the linked pad
    and keeps sliding the same way. If the linked pad is occupied, the marble
    stops before the pad. A marble can use the same pad only once per swipe.
  * If a marble enters an open hole of its own color, it drops in; the hole is
    then filled and behaves like floor. Other colors roll over holes.
  * The level is solved when no marbles are left.
"""
import argparse
import json
import random
from collections import deque

DIRS = {"U": (0, -1), "D": (0, 1), "L": (-1, 0), "R": (1, 0)}
COLORS = "rgbyp"


def parse(rows):
    walls, holes, marbles, pads = set(), {}, [], {}
    for y, row in enumerate(rows):
        for x, c in enumerate(row):
            if c == "#":
                walls.add((x, y))
            elif c.islower():
                marbles.append((x, y, c))
            elif c.isupper():
                holes[(x, y)] = c.lower()
            elif c.isdigit():
                pads.setdefault(c, []).append((x, y))
    portals = {}
    for cells in pads.values():
        if len(cells) == 2:
            portals[cells[0]] = cells[1]
            portals[cells[1]] = cells[0]
    return walls, holes, marbles, portals


def slide(w, h, walls, portals, marbles, holes, d, stats=None):
    """marbles: tuple of (x, y, color). holes: dict (x, y) -> color (open holes).
    Returns (new_marbles_sorted_tuple, new_holes_dict)."""
    dx, dy = DIRS[d]
    # Leading edge first; ties broken by x then y so the order is always the same.
    order = sorted(marbles, key=lambda m: (-(m[0] * dx + m[1] * dy), m[0], m[1]))
    occupied = {(m[0], m[1]) for m in marbles}
    open_h = dict(holes)
    out = []
    for (x, y, c) in order:
        occupied.discard((x, y))
        dropped = False
        used = set()
        while True:
            nx, ny = x + dx, y + dy
            if nx < 0 or ny < 0 or nx >= w or ny >= h or (nx, ny) in walls or (nx, ny) in occupied:
                break
            if (nx, ny) in portals:
                if (nx, ny) in used or portals[(nx, ny)] in occupied:
                    break
                used.add((nx, ny))
                x, y = portals[(nx, ny)]
                if stats is not None:
                    stats["teleports"] += 1
            else:
                x, y = nx, ny
            if open_h.get((x, y)) == c:
                del open_h[(x, y)]
                dropped = True
                break
        if not dropped:
            occupied.add((x, y))
            out.append((x, y, c))
    return tuple(sorted(out)), open_h


def key(marbles, holes):
    return (marbles, tuple(sorted(holes.items())))


def solve(rows, max_states=300_000):
    """Breadth-first search. Returns (path_string or None, states_explored)."""
    walls, holes, marbles, portals = parse(rows)
    w, h = len(rows[0]), len(rows)
    start_m = tuple(sorted(marbles))
    if not start_m:
        return "", 1
    start = key(start_m, holes)
    prev = {start: None}
    queue = deque([(start_m, holes)])
    while queue and len(prev) < max_states:
        m, hl = queue.popleft()
        k0 = key(m, hl)
        for d in "ULDR":
            nm, nh = slide(w, h, walls, portals, m, hl, d)
            k = key(nm, nh)
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
            queue.append((nm, nh))
    return None, len(prev)


def teleports_used(rows, path):
    walls, holes, marbles, portals = parse(rows)
    w, h = len(rows[0]), len(rows)
    m, hl = tuple(sorted(marbles)), holes
    stats = {"teleports": 0}
    for d in path:
        m, hl = slide(w, h, walls, portals, m, hl, d, stats)
    return stats["teleports"]


def random_level(rng, size, per_color, n_portals, wall_density):
    w = h = size + 2
    grid = [["#" if x in (0, w - 1) or y in (0, h - 1) else "." for x in range(w)] for y in range(h)]
    interior = [(x, y) for y in range(1, h - 1) for x in range(1, w - 1)]
    rng.shuffle(interior)
    n_walls = int(len(interior) * wall_density)
    for (x, y) in interior[:n_walls]:
        grid[y][x] = "#"
    free = interior[n_walls:]
    for i in range(n_portals):
        for _ in range(2):
            x, y = free.pop()
            grid[y][x] = str(i + 1)
    for i, count in enumerate(per_color):
        c = COLORS[i]
        for _ in range(count):
            mx, my = free.pop()
            hx, hy = free.pop()
            grid[my][mx] = c
            grid[hy][hx] = c.upper()
    return ["".join(r) for r in grid]


# Each world adds one idea. Entries: (interior size, marbles per color, portal pairs,
# wall density, min par, max par). Difficulty rises inside each world.
WORLDS = [
    {"name": "Meadow", "intro": "Swipe to tilt. Every marble slides until it hits something.", "curve": [
        (5, [1], 0, .12, 2, 3), (5, [1], 0, .15, 3, 4), (5, [1], 0, .18, 4, 5),
        (5, [1, 1], 0, .12, 3, 4), (5, [1, 1], 0, .15, 4, 5), (5, [1], 0, .20, 5, 6),
        (6, [1, 1], 0, .15, 5, 6), (6, [1, 1], 0, .18, 5, 7), (6, [1, 1, 1], 0, .12, 5, 7),
        (6, [1], 0, .20, 6, 8), (6, [1, 1, 1], 0, .15, 6, 8), (6, [1, 1, 1], 0, .18, 7, 10),
    ]},
    {"name": "Pond", "intro": "Some colors have more than one marble. Fill every hole.", "curve": [
        (5, [2], 0, .12, 3, 4), (5, [2], 0, .15, 4, 5), (5, [2, 1], 0, .12, 4, 6),
        (6, [2], 0, .15, 5, 6), (6, [2, 1], 0, .15, 5, 7), (6, [2, 2], 0, .12, 5, 7),
        (6, [3], 0, .15, 5, 7), (6, [2, 1, 1], 0, .15, 6, 8), (6, [2, 2], 0, .18, 6, 9),
        (7, [2, 2, 1], 0, .15, 6, 9), (7, [3, 2], 0, .15, 7, 10), (7, [2, 2, 2], 0, .15, 8, 12),
    ]},
    {"name": "Portal Grove", "intro": "Teleport pads send a marble to the matching pad.", "curve": [
        (5, [1], 1, .12, 3, 4), (5, [1], 1, .15, 3, 5), (5, [1, 1], 1, .12, 4, 5),
        (6, [1], 1, .15, 4, 6), (6, [1, 1], 1, .15, 5, 6), (6, [2], 1, .15, 5, 7),
        (6, [1, 1], 2, .12, 5, 7), (6, [2, 1], 1, .15, 6, 8), (6, [1, 1, 1], 2, .12, 6, 8),
        (7, [2, 1], 2, .15, 6, 9), (7, [2, 2], 2, .15, 7, 10), (7, [2, 1, 1], 2, .15, 8, 12),
    ]},
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--tries", type=int, default=3000)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    worlds_out = []
    n = 0
    for world in WORLDS:
        levels = []
        for (size, per_color, portals, dens, lo, hi) in world["curve"]:
            n += 1
            best = None
            marbles = sum(per_color)
            for _ in range(args.tries):
                rows = random_level(rng, size, per_color, portals, dens)
                path, states = solve(rows)
                if path is None or not (lo <= len(path) <= hi) or len(set(path)) == 1:
                    continue
                if portals and teleports_used(rows, path) == 0:
                    continue
                if best is None or states > best[2]:
                    best = (rows, path, states)
                if states > 60 * marbles:
                    break
            if best is None:
                raise SystemExit(f"Could not generate level {n}; loosen its settings.")
            rows, path, states = best
            levels.append({"id": n, "rows": rows, "par": len(path), "solution": path})
            print(f"{world['name']:12} level {n:2}: {size}x{size}, marbles {per_color}, portals {portals}, par {len(path):2}, {states} states")
        worlds_out.append({"name": world["name"], "intro": world["intro"], "levels": levels})
    with open(args.out, "w") as f:
        json.dump({"worlds": worlds_out}, f, indent=2)
        f.write("\n")
    print(f"Wrote {n} levels to {args.out}")


if __name__ == "__main__":
    main()
