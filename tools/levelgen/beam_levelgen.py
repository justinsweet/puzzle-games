#!/usr/bin/env python3
"""Beam level generator and solver.

Level format (JSON):
  rows:     list of strings. '#' wall, '.' empty, '/' or '\\' mirror (its starting angle)
  emitters: [{"x", "y", "dir": "U|D|L|R", "color"}]   fire a beam of that color
  targets:  [{"x", "y", "color"}]                     crystals to light

Rules (must match games/beam/scripts/beam_rules.gd exactly):
  * Tapping a mirror flips it between '/' and '\\'.
  * A beam travels in a straight line from its emitter. A mirror turns it 90 degrees.
  * Walls, emitters and the board edge stop a beam.
  * A crystal stops any beam that reaches it; it lights up only if the colors match.
  * Beams pass through each other. A beam that loops forever is stopped.
  * The level is solved when every crystal is lit.
"""
import argparse
import itertools
import json
import random

DIRS = {"U": (0, -1), "D": (0, 1), "L": (-1, 0), "R": (1, 0)}
COLORS = "rgb"


def reflect(d, m):
    dx, dy = d
    return (-dy, -dx) if m == "/" else (dy, dx)


def parse(level):
    rows = level["rows"]
    walls, mirrors = set(), {}
    for y, row in enumerate(rows):
        for x, c in enumerate(row):
            if c == "#":
                walls.add((x, y))
            elif c in "/\\":
                mirrors[(x, y)] = c
    emitters = [((e["x"], e["y"]), DIRS[e["dir"]], e["color"]) for e in level["emitters"]]
    targets = {(t["x"], t["y"]): t["color"] for t in level["targets"]}
    return len(rows[0]), len(rows), walls, mirrors, emitters, targets


def trace(w, h, walls, mirrors, emitters, targets):
    """Returns (lit_target_positions, beams) where each beam is (color, [cells visited])."""
    lit, beams = set(), []
    blockers = {e[0] for e in emitters}
    for (pos, d, color) in emitters:
        x, y = pos
        cells, seen = [], set()
        while True:
            nx, ny = x + d[0], y + d[1]
            if nx < 0 or ny < 0 or nx >= w or ny >= h or (nx, ny) in walls or (nx, ny) in blockers:
                break
            x, y = nx, ny
            if (x, y, d) in seen:
                break
            seen.add((x, y, d))
            cells.append((x, y))
            if (x, y) in targets:
                if targets[(x, y)] == color:
                    lit.add((x, y))
                break
            if (x, y) in mirrors:
                d = reflect(d, mirrors[(x, y)])
        beams.append((color, cells))
    return lit, beams


def solved(w, h, walls, mirrors, emitters, targets):
    lit, _ = trace(w, h, walls, mirrors, emitters, targets)
    return len(lit) == len(targets)


def solve(level):
    """Brute force over every mirror setting. Returns (fewest_taps_list, number_of_solutions)."""
    w, h, walls, mirrors, emitters, targets = parse(level)
    keys = sorted(mirrors)
    best, count = None, 0
    for combo in itertools.product("/\\", repeat=len(keys)):
        setting = dict(zip(keys, combo))
        if solved(w, h, walls, setting, emitters, targets):
            count += 1
            taps = [k for k in keys if setting[k] != mirrors[k]]
            if best is None or len(taps) < len(best):
                best = taps
    return best, count


def random_level(rng, size, n_emitters, n_mirrors, wall_density, min_bounces):
    w = h = size
    cells = [(x, y) for y in range(h) for x in range(w)]
    for _ in range(200):
        rng.shuffle(cells)
        walls = set(cells[: int(len(cells) * wall_density)])
        free = [c for c in cells if c not in walls]
        mirror_cells = free[:n_mirrors]
        rest = free[n_mirrors:]
        goal = {c: rng.choice("/\\") for c in mirror_cells}
        emitters = []
        for i in range(n_emitters):
            pos = rest.pop()
            emitters.append((pos, DIRS[rng.choice("UDLR")], COLORS[i]))
        # Trace each beam in the goal setting and put its crystal where it ends.
        targets = {}
        ok = True
        for e in emitters:
            _, beams = trace(w, h, walls, goal, [e], targets)
            color, path = beams[0]
            bounces = sum(1 for c in path if c in goal)
            end = path[-1] if path else None
            if end is None or end in goal or end in targets or bounces < min_bounces \
                    or any(end == other[0] for other in emitters):
                ok = False
                break
            targets[end] = color
        if not ok or not solved(w, h, walls, goal, emitters, targets):
            continue
        # Scramble: start from a random setting that is not already solved.
        start = {c: rng.choice("/\\") for c in mirror_cells}
        if solved(w, h, walls, start, emitters, targets):
            continue
        rows = []
        for y in range(h):
            row = ""
            for x in range(w):
                row += "#" if (x, y) in walls else start.get((x, y), ".")
            rows.append(row)
        inv = {v: k for k, v in DIRS.items()}
        return {
            "rows": rows,
            "emitters": [{"x": p[0], "y": p[1], "dir": inv[d], "color": c} for p, d, c in emitters],
            "targets": [{"x": p[0], "y": p[1], "color": c} for p, c in targets.items()],
        }
    return None


# (board size, beams, mirrors, wall density, min bounces per beam, min par, max par)
CURVE = [
    (5, 1, 2, 0.08, 1, 1, 1),
    (5, 1, 3, 0.08, 2, 1, 2),
    (5, 1, 4, 0.10, 2, 2, 3),
    (6, 1, 5, 0.10, 3, 2, 3),
    (6, 2, 5, 0.08, 1, 2, 3),
    (6, 1, 6, 0.12, 3, 3, 4),
    (6, 2, 6, 0.10, 2, 3, 4),
    (7, 2, 7, 0.10, 2, 3, 5),
    (7, 2, 8, 0.10, 3, 4, 6),
    (7, 3, 9, 0.08, 2, 4, 7),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--tries", type=int, default=3000)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    levels = []
    for i, (size, beams, mirrors, dens, bounces, lo, hi) in enumerate(CURVE, start=1):
        best = None
        for _ in range(args.tries):
            lvl = random_level(rng, size, beams, mirrors, dens, bounces)
            if lvl is None:
                continue
            taps, count = solve(lvl)
            if taps is None or not (lo <= len(taps) <= hi):
                continue
            # Prefer levels with fewer solutions (less guessable).
            if best is None or count < best[2]:
                best = (lvl, taps, count)
            if count <= 2:
                break
        if best is None:
            raise SystemExit(f"Could not generate level {i}; loosen its settings in CURVE.")
        lvl, taps, count = best
        lvl = {"id": i, **lvl, "par": len(taps), "solution": [list(t) for t in taps]}
        levels.append(lvl)
        print(f"Level {i:2}: {size}x{size}, {beams} beam(s), {mirrors} mirrors, par {len(taps)}, {count} solution(s)")
    with open(args.out, "w") as f:
        json.dump({"levels": levels}, f, indent=2)
        f.write("\n")
    print(f"Wrote {len(levels)} levels to {args.out}")


if __name__ == "__main__":
    main()
