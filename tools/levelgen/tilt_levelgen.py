#!/usr/bin/env python3
"""Tilt level generator and solver.

Level format: a list of equal-length strings (rows).
  '#' wall   '.' floor
  lowercase letter (r g b y p) = marble of that color
  uppercase letter (R G B Y P) = hole of that color

Rules (must match games/tilt/scripts/tilt_rules.gd exactly):
  * A swipe moves every marble in that direction. Marbles are processed
    leading edge first (closest to the wall they are moving toward).
  * A marble slides until the next cell is a wall, outside the board,
    or another marble.
  * If it enters an open hole of its own color, it drops in; the hole
    is then filled and behaves like floor. Other colors roll over holes.
  * The level is solved when no marbles are left.
"""
import argparse
import json
import random
from collections import deque

DIRS = {"U": (0, -1), "D": (0, 1), "L": (-1, 0), "R": (1, 0)}
COLORS = "rgbyp"


def parse(rows):
    walls, holes, marbles = set(), {}, []
    for y, row in enumerate(rows):
        for x, c in enumerate(row):
            if c == "#":
                walls.add((x, y))
            elif c.islower():
                marbles.append((x, y, c))
            elif c.isupper():
                holes[(x, y)] = c.lower()
    return walls, holes, marbles


def slide(w, h, walls, marbles, holes, d):
    """marbles: tuple of (x, y, color). holes: dict (x, y) -> color (open holes).
    Returns (new_marbles_sorted_tuple, new_holes_dict)."""
    dx, dy = DIRS[d]
    order = sorted(marbles, key=lambda m: -(m[0] * dx + m[1] * dy))
    occupied = {(m[0], m[1]) for m in marbles}
    open_h = dict(holes)
    out = []
    for (x, y, c) in order:
        occupied.discard((x, y))
        dropped = False
        while True:
            nx, ny = x + dx, y + dy
            if nx < 0 or ny < 0 or nx >= w or ny >= h or (nx, ny) in walls or (nx, ny) in occupied:
                break
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
    walls, holes, marbles = parse(rows)
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
            nm, nh = slide(w, h, walls, m, hl, d)
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


def random_level(rng, size, colors, wall_density):
    w = h = size + 2
    grid = [["#" if x in (0, w - 1) or y in (0, h - 1) else "." for x in range(w)] for y in range(h)]
    interior = [(x, y) for y in range(1, h - 1) for x in range(1, w - 1)]
    rng.shuffle(interior)
    n_walls = int(len(interior) * wall_density)
    for (x, y) in interior[:n_walls]:
        grid[y][x] = "#"
    free = interior[n_walls:]
    for i in range(colors):
        c = COLORS[i]
        mx, my = free.pop()
        hx, hy = free.pop()
        grid[my][mx] = c
        grid[hy][hx] = c.upper()
    return ["".join(r) for r in grid]


def boring(path):
    # Reject levels that are just one direction repeated, or a simple back-and-forth.
    return len(set(path)) == 1


# Difficulty curve for the first prototype levels:
# (interior size, colors, wall density, min par, max par)
CURVE = [
    (5, 1, 0.12, 2, 3),
    (5, 1, 0.15, 3, 4),
    (5, 1, 0.18, 4, 5),
    (5, 2, 0.12, 3, 4),
    (5, 2, 0.15, 4, 6),
    (6, 2, 0.15, 5, 7),
    (5, 1, 0.20, 5, 7),
    (6, 2, 0.18, 6, 8),
    (6, 3, 0.12, 5, 8),
    (6, 3, 0.15, 7, 10),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--tries", type=int, default=20000)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    levels = []
    for i, (size, colors, dens, lo, hi) in enumerate(CURVE, start=1):
        best = None
        for _ in range(args.tries):
            rows = random_level(rng, size, colors, dens)
            path, states = solve(rows)
            if path is None or not (lo <= len(path) <= hi) or boring(path):
                continue
            # Prefer levels with more reachable states (more ways to go wrong).
            if best is None or states > best[2]:
                best = (rows, path, states)
            if states > 40 * colors:
                break
        if best is None:
            raise SystemExit(f"Could not generate level {i}; loosen its settings in CURVE.")
        rows, path, states = best
        levels.append({"id": i, "rows": rows, "par": len(path), "solution": path})
        print(f"Level {i:2}: {size}x{size}, {colors} color(s), par {len(path):2}, {states} states  {path}")
    with open(args.out, "w") as f:
        json.dump({"levels": levels}, f, indent=2)
        f.write("\n")
    print(f"Wrote {len(levels)} levels to {args.out}")


if __name__ == "__main__":
    main()
