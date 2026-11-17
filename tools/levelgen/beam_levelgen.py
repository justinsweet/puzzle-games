#!/usr/bin/env python3
"""Beam level generator and solver.

Level format (JSON):
  rows:     strings. '#' wall, '.' empty, '/' or '\\' mirror (starting angle), digit 1-4 = portal pad
  emitters: [{"x", "y", "dir": "U|D|L|R", "color"}]  fire a beam (r, y or b)
  targets:  [{"x", "y", "color"}]                    crystals to light
  filters:  [{"x", "y", "color"}]                    only that color passes; others stop
  tints:    [{"x", "y", "color"}]                    colored glass: mixes its color into the beam
  movers:   [{"x", "y", "m": "/" or "\\"}]           mirrors the player can drag (and flip)
  goal:     {"mirrors": {"x,y": "/"}, "movers": [{"x", "y", "m"}]}   one solved setting (for hints)

Colors mix like paint: r + y = o (orange), y + b = g (green), r + b = p (purple), all three = w.

Rules (must match games/beam/scripts/beam_rules.gd exactly):
  * Tapping any mirror flips it between '/' and '\\'. Dragging a mover puts it on an empty cell.
  * A beam travels in a straight line from its emitter. A mirror turns it 90 degrees.
  * Walls, emitters and the board edge stop a beam.
  * A crystal stops any beam that reaches it; it lights up only if the colors match exactly.
  * A filter stops every beam except its own color.
  * Colored glass mixes its color into the beam that passes through.
  * A portal pad sends the beam out of its linked pad, same direction.
  * Beams pass through each other. A beam that loops forever is stopped.
  * The level is solved when every crystal is lit.
"""
import argparse
import itertools
import json
import random

DIRS = {"U": (0, -1), "D": (0, 1), "L": (-1, 0), "R": (1, 0)}
INV_DIRS = {v: k for k, v in DIRS.items()}
BITS = {"r": 1, "y": 2, "b": 4, "o": 3, "g": 6, "p": 5, "w": 7}
NAMES = {v: k for k, v in BITS.items()}
PRIMARIES = "ryb"


def reflect(d, m):
    dx, dy = d
    return (-dy, -dx) if m == "/" else (dy, dx)


class Board:
    def __init__(self, level):
        rows = level["rows"]
        self.w, self.h = len(rows[0]), len(rows)
        self.walls, self.fixed, pads = set(), {}, {}
        for y, row in enumerate(rows):
            for x, c in enumerate(row):
                if c == "#":
                    self.walls.add((x, y))
                elif c in "/\\":
                    self.fixed[(x, y)] = c
                elif c.isdigit():
                    pads.setdefault(c, []).append((x, y))
        self.portals = {}
        for cells in pads.values():
            if len(cells) == 2:
                self.portals[cells[0]] = cells[1]
                self.portals[cells[1]] = cells[0]
        self.emitters = [((e["x"], e["y"]), DIRS[e["dir"]], BITS[e["color"]]) for e in level["emitters"]]
        self.targets = {(t["x"], t["y"]): BITS[t["color"]] for t in level["targets"]}
        self.filters = {(f["x"], f["y"]): BITS[f["color"]] for f in level.get("filters", [])}
        self.tints = {(t["x"], t["y"]): BITS[t["color"]] for t in level.get("tints", [])}
        self.movers = [((m["x"], m["y"]), m["m"]) for m in level.get("movers", [])]

    def trace(self, mirrors):
        """mirrors: dict (x, y) -> '/' or '\\' (fixed and movers together).
        Returns (lit set, beams) where a beam is a list of (cell, color_bits) visited."""
        lit, beams = set(), []
        blockers = {e[0] for e in self.emitters}
        for (pos, d, color) in self.emitters:
            x, y = pos
            c = color
            seen, path = set(), []
            while True:
                nx, ny = x + d[0], y + d[1]
                if nx < 0 or ny < 0 or nx >= self.w or ny >= self.h or (nx, ny) in self.walls or (nx, ny) in blockers:
                    break
                x, y = nx, ny
                if (x, y, d, c) in seen:
                    break
                seen.add((x, y, d, c))
                path.append(((x, y), c))
                if (x, y) in self.targets:
                    if self.targets[(x, y)] == c:
                        lit.add((x, y))
                    break
                if (x, y) in self.filters and self.filters[(x, y)] != c:
                    break
                if (x, y) in self.tints:
                    c |= self.tints[(x, y)]
                if (x, y) in self.portals:
                    x, y = self.portals[(x, y)]
                    path.append(((x, y), c))
                if (x, y) in mirrors:
                    d = reflect(d, mirrors[(x, y)])
            beams.append(path)
        return lit, beams

    def solved(self, mirrors):
        return len(self.trace(mirrors)[0]) == len(self.targets)

    def setting(self, fixed, movers):
        s = dict(fixed)
        for pos, m in movers:
            s[pos] = m
        return s


def min_fixed_flips(board, movers):
    """Fewest flips of fixed mirrors that solve the board with movers where they are."""
    keys = sorted(board.fixed)
    best = None
    for combo in itertools.product("/\\", repeat=len(keys)):
        fixed = dict(zip(keys, combo))
        if board.solved(board.setting(fixed, movers)):
            flips = [k for k in keys if fixed[k] != board.fixed[k]]
            if best is None or len(flips) < len(best[0]):
                best = (flips, fixed)
    return best


def random_level(rng, spec):
    size = spec["size"]
    w = h = size
    for _ in range(300):
        cells = [(x, y) for y in range(h) for x in range(w)]
        rng.shuffle(cells)
        walls = set(cells[: int(len(cells) * spec["walls"])])
        free = [c for c in cells if c not in walls]
        portals = {}
        pad_ids = {}
        for i in range(spec.get("portals", 0)):
            a, b = free.pop(), free.pop()
            portals[a], portals[b] = b, a
            pad_ids[a] = pad_ids[b] = str(i + 1)
        fixed_goal = {free.pop(): rng.choice("/\\") for _ in range(spec["mirrors"])}
        mover_goal = [(free.pop(), rng.choice("/\\")) for _ in range(spec.get("movers", 0))]
        colors = rng.sample(PRIMARIES, spec["beams"])
        emitters = [(free.pop(), rng.choice(list(DIRS.values())), BITS[c]) for c in colors]
        level = {"rows": None, "emitters": [], "targets": [], "filters": [], "tints": [], "movers": []}

        def build(fixed_start, mover_start, targets, filters, tints):
            rows = []
            for y in range(h):
                row = ""
                for x in range(w):
                    p = (x, y)
                    row += "#" if p in walls else pad_ids.get(p) or fixed_start.get(p, ".")
                rows.append(row)
            return {
                "rows": rows,
                "emitters": [{"x": p[0], "y": p[1], "dir": INV_DIRS[d], "color": NAMES[c]} for p, d, c in emitters],
                "targets": [{"x": p[0], "y": p[1], "color": NAMES[c]} for p, c in targets.items()],
                "filters": [{"x": p[0], "y": p[1], "color": NAMES[c]} for p, c in filters.items()],
                "tints": [{"x": p[0], "y": p[1], "color": NAMES[c]} for p, c in tints.items()],
                "movers": [{"x": p[0], "y": p[1], "m": m} for p, m in mover_start],
            }

        special = set(fixed_goal) | {p for p, _ in mover_goal} | {e[0] for e in emitters} | set(portals)
        targets, filters, tints = {}, {}, {}
        goal_setting = dict(fixed_goal)
        for p, m in mover_goal:
            goal_setting[p] = m
        ok = True
        # Add colored glass on the goal paths, then filters, then crystals at the ends.
        for _ in range(spec.get("tints", 0)):
            b = Board(build(fixed_goal, [], targets, filters, tints))
            beam = rng.choice(b.trace(goal_setting)[1])
            options = [(p, c) for p, c in beam[:-1] if p not in special and p not in tints]
            options = [(p, c) for p, c in options if any(not (c & BITS[t]) for t in PRIMARIES)]
            if not options:
                ok = False
                break
            p, c = rng.choice(options)
            tints[p] = BITS[rng.choice([t for t in PRIMARIES if not (c & BITS[t])])]
            special.add(p)
        if not ok:
            continue
        for _ in range(spec.get("filters", 0)):
            b = Board(build(fixed_goal, [], targets, filters, tints))
            beam = rng.choice(b.trace(goal_setting)[1])
            options = [(p, c) for p, c in beam[:-1] if p not in special]
            if not options:
                ok = False
                break
            p, c = rng.choice(options)
            filters[p] = c
            special.add(p)
        if not ok:
            continue
        b = Board(build(fixed_goal, [], targets, filters, tints))
        for path in b.trace(goal_setting)[1]:
            bounces = sum(1 for p, _ in path if p in goal_setting)
            if not path or bounces < spec["bounces"]:
                ok = False
                break
            end, c = path[-1]
            if end in special or end in targets:
                ok = False
                break
            targets[end] = c
            special.add(end)
        if not ok:
            continue
        if spec.get("tints") and all(c in (1, 2, 4) for c in targets.values()):
            continue  # make sure mixing actually matters
        if portals and not any(p in portals for path in b.trace(goal_setting)[1] for p, _ in path):
            continue  # make sure a beam actually goes through a portal
        goal_level = build(fixed_goal, mover_goal, targets, filters, tints)
        if not Board(goal_level).solved(goal_setting):
            continue
        # Scramble: flip mirrors at random and put movers on random empty cells.
        fixed_start = {p: rng.choice("/\\") for p in fixed_goal}
        empties = [c for c in free if c not in special]
        rng.shuffle(empties)
        mover_start = [(empties.pop(), rng.choice("/\\")) for _ in mover_goal]
        level = build(fixed_start, mover_start, targets, filters, tints)
        board = Board(level)
        if board.solved(board.setting(board.fixed, board.movers)):
            continue
        return level, fixed_goal, mover_goal
    return None


def score(level, fixed_goal, mover_goal):
    """Returns (par, goal) or None. Levels without movers get an exact par by brute force.
    With movers, par = moves to reach the generator's goal (an upper bound), and we
    require that the level cannot be solved without moving them."""
    board = Board(level)
    if not board.movers:
        best = min_fixed_flips(board, [])
        if best is None:
            return None
        flips, fixed = best
        return len(flips), {"mirrors": {f"{x},{y}": m for (x, y), m in fixed.items()}, "movers": []}
    if min_fixed_flips(board, board.movers) is not None:
        return None  # solvable without dragging; not interesting
    best = min_fixed_flips(board, mover_goal)
    if best is None:
        return None
    flips, fixed = best
    cost = len(flips)
    starts = list(board.movers)
    for gp, gm in mover_goal:
        match = next((s for s in starts if s[0] == gp), None) or starts[0]
        starts.remove(match)
        cost += (0 if match[0] == gp else 1) + (0 if match[1] == gm else 1)
    goal = {"mirrors": {f"{x},{y}": m for (x, y), m in fixed.items()},
            "movers": [{"x": p[0], "y": p[1], "m": m} for p, m in mover_goal]}
    return cost, goal


def solution_count(level):
    board = Board(level)
    if board.movers:
        return 1
    keys = sorted(board.fixed)
    return sum(1 for combo in itertools.product("/\\", repeat=len(keys))
               if board.solved(dict(zip(keys, combo))))


def S(size, beams, mirrors, walls, bounces, lo, hi, **extra):
    return dict(size=size, beams=beams, mirrors=mirrors, walls=walls, bounces=bounces, lo=lo, hi=hi, **extra)


WORLDS = [
    {"name": "Mirror Lab", "intro": "Tap a mirror to flip it. Light every crystal.", "curve": [
        S(5, 1, 2, .08, 1, 1, 1), S(5, 1, 3, .08, 2, 1, 2), S(5, 1, 4, .10, 2, 2, 3),
        S(6, 1, 5, .10, 3, 2, 3), S(6, 2, 5, .08, 1, 2, 3), S(6, 1, 6, .12, 3, 3, 4),
        S(6, 2, 6, .10, 2, 3, 4), S(7, 2, 7, .10, 2, 3, 5), S(7, 2, 8, .10, 3, 4, 6),
        S(7, 3, 9, .08, 2, 4, 7),
    ]},
    {"name": "Filter Works", "intro": "Filters only let their own color through.", "curve": [
        S(5, 1, 3, .08, 1, 1, 2, filters=1), S(5, 2, 4, .08, 1, 2, 3, filters=1),
        S(6, 2, 5, .08, 1, 2, 3, filters=2), S(6, 2, 5, .10, 2, 2, 4, filters=2),
        S(6, 2, 6, .08, 2, 3, 4, filters=2), S(6, 3, 6, .08, 1, 3, 5, filters=2),
        S(7, 2, 7, .08, 2, 3, 5, filters=3), S(7, 3, 7, .08, 2, 3, 6, filters=3),
        S(7, 3, 8, .08, 2, 4, 6, filters=3), S(7, 3, 9, .08, 2, 4, 7, filters=4),
    ]},
    {"name": "Color Studio", "intro": "Colored glass mixes colors: red + yellow = orange.", "curve": [
        S(5, 1, 2, .08, 1, 1, 2, tints=1), S(5, 1, 3, .08, 1, 1, 2, tints=1),
        S(6, 2, 4, .08, 1, 2, 3, tints=1), S(6, 1, 5, .08, 2, 2, 3, tints=2),
        S(6, 2, 5, .08, 1, 2, 4, tints=1, filters=1), S(6, 2, 6, .08, 2, 3, 4, tints=2),
        S(7, 2, 6, .08, 2, 3, 5, tints=2, filters=1), S(7, 3, 7, .08, 1, 3, 5, tints=2),
        S(7, 3, 8, .08, 2, 3, 6, tints=2, filters=2), S(7, 3, 9, .08, 2, 4, 7, tints=3, filters=1),
    ]},
    {"name": "Warp Gallery", "intro": "Drag the handled mirrors into place. Portals bend space.", "curve": [
        S(5, 1, 1, .08, 1, 2, 3, movers=1), S(5, 1, 2, .08, 2, 2, 4, movers=1),
        S(6, 1, 2, .08, 1, 2, 4, portals=1), S(6, 2, 3, .08, 1, 2, 5, movers=1),
        S(6, 1, 3, .08, 2, 3, 5, movers=1, portals=1), S(6, 2, 4, .08, 1, 3, 5, portals=1, tints=1),
        S(7, 2, 4, .08, 2, 3, 6, movers=2), S(7, 2, 5, .08, 2, 3, 6, movers=1, portals=1, filters=1),
        S(7, 3, 5, .08, 2, 4, 7, movers=2, tints=1), S(7, 3, 6, .08, 2, 4, 8, movers=2, portals=1, tints=1),
    ]},
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--tries", type=int, default=600)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    worlds_out, n = [], 0
    for world in WORLDS:
        levels = []
        for spec in world["curve"]:
            n += 1
            best = None
            for _ in range(args.tries):
                made = random_level(rng, spec)
                if made is None:
                    continue
                level, fixed_goal, mover_goal = made
                scored = score(level, fixed_goal, mover_goal)
                if scored is None or not (spec["lo"] <= scored[0] <= spec["hi"]):
                    continue
                count = solution_count(level)
                if best is None or count < best[2]:
                    best = (level, scored, count)
                if count <= 2:
                    break
            if best is None:
                raise SystemExit(f"Could not generate level {n} ({world['name']}); loosen its settings.")
            level, (par, goal), count = best
            levels.append({"id": n, **level, "par": par, "goal": goal})
            extras = {k: spec[k] for k in ("filters", "tints", "movers", "portals") if k in spec}
            print(f"{world['name']:13} level {n:2}: {spec['size']}x{spec['size']}, {spec['beams']} beam(s), "
                  f"{spec['mirrors']} mirrors {extras}, par {par}, {count} solution(s)")
        worlds_out.append({"name": world["name"], "intro": world["intro"], "levels": levels})
    with open(args.out, "w") as f:
        json.dump({"worlds": worlds_out}, f, indent=2)
        f.write("\n")
    print(f"Wrote {n} levels to {args.out}")


if __name__ == "__main__":
    main()
