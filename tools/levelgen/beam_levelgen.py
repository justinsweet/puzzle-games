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
  links:    [[[x, y], [x, y]]]                   twin mirrors: tapping one flips both
  shadows:  [[x, y]]                             shadow crystals: the level fails while any beam touches one
  max_bounces: n                                 beams fade after n mirror bounces
  prisms:   [[x, y]]                             split white light: red turns left, yellow goes straight, blue turns right
  gates:    [{"x", "y", "id"}]                   closed until a crystal with "opens": id is lit
  (targets may have "opens": id)

Colors mix like paint: r + y = o (orange), y + b = g (green), r + b = p (purple), all three = w.

Rules (must match games/beam/scripts/beam_rules.gd exactly):
  * Tapping any mirror flips it between '/' and '\\'. Dragging a mover puts it on an empty cell.
  * A beam travels in a straight line from its emitter. A mirror turns it 90 degrees.
  * Walls, emitters and the board edge stop a beam.
  * A crystal stops any beam that reaches it; it lights up only if the colors match exactly.
  * A filter stops every beam except its own color.
  * Colored glass mixes its color into the beam that passes through.
  * A portal pad sends the beam out of its linked pad, same direction.
  * A shadow crystal stops a beam; while any beam touches one, the level is not solved.
  * A prism stops a white beam and sends out red (turned left), yellow (straight) and blue
    (turned right) beams from the prism. Colored beams pass through prisms unchanged.
  * With max_bounces, a beam stops at the mirror that would be one bounce too many.
  * Gates block beams until a crystal that opens them is lit. The board is traced again
    with the gates that the lit crystals open, until nothing changes (at most 8 times).
  * Beams pass through each other. A beam that loops forever is stopped.
  * The level is solved when every crystal is lit and no shadow crystal is touched.
"""
import argparse
import itertools
import json
import os
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
        self.links = [[tuple(a), tuple(b)] for a, b in level.get("links", [])]
        self.shadows = {tuple(p) for p in level.get("shadows", [])}
        self.max_bounces = level.get("max_bounces", 0)
        self.prisms = {tuple(p) for p in level.get("prisms", [])}
        self.gates = {(g["x"], g["y"]): g["id"] for g in level.get("gates", [])}
        self.opens = {(t["x"], t["y"]): t["opens"] for t in level["targets"] if "opens" in t}

    def trace_once(self, mirrors, opened):
        """One pass. Returns (lit set, shadow_touched, beams) where a beam is a dict with
        "path": [(cell, color_bits)], "bounces", "split" (ended in a prism)."""
        lit, beams, shadow = set(), [], False
        blockers = {e[0] for e in self.emitters}
        queue = [(pos, d, color) for (pos, d, color) in self.emitters]
        qi = 0
        while qi < len(queue):
            (pos, d, color) = queue[qi]
            qi += 1
            x, y = pos
            c = color
            seen, path, bounces, split = set(), [], 0, False
            while True:
                nx, ny = x + d[0], y + d[1]
                if nx < 0 or ny < 0 or nx >= self.w or ny >= self.h or (nx, ny) in self.walls or (nx, ny) in blockers:
                    break
                if (nx, ny) in self.gates and self.gates[(nx, ny)] not in opened:
                    break
                x, y = nx, ny
                if (x, y, d, c) in seen:
                    break
                seen.add((x, y, d, c))
                path.append(((x, y), c))
                if (x, y) in self.shadows:
                    shadow = True
                    break
                if (x, y) in self.targets:
                    if self.targets[(x, y)] == c:
                        lit.add((x, y))
                    break
                if (x, y) in self.filters and self.filters[(x, y)] != c:
                    break
                if (x, y) in self.tints:
                    c |= self.tints[(x, y)]
                if (x, y) in self.prisms and c == 7:
                    dx, dy = d
                    queue.append(((x, y), (dy, -dx), 1))
                    queue.append(((x, y), d, 2))
                    queue.append(((x, y), (-dy, dx), 4))
                    split = True
                    break
                if (x, y) in self.portals:
                    x, y = self.portals[(x, y)]
                    path.append(((x, y), c))
                if (x, y) in mirrors:
                    if self.max_bounces and bounces >= self.max_bounces:
                        break
                    d = reflect(d, mirrors[(x, y)])
                    bounces += 1
            beams.append({"path": path, "bounces": bounces, "split": split})
        return lit, shadow, beams

    def trace_full(self, mirrors):
        opened = frozenset()
        for _ in range(8):
            lit, shadow, beams = self.trace_once(mirrors, opened)
            new = frozenset(self.opens[p] for p in lit if p in self.opens)
            if new == opened:
                break
            opened = new
        return lit, shadow, beams

    def trace(self, mirrors):
        """Returns (lit set, beams) where a beam is a list of (cell, color_bits) visited."""
        lit, shadow, beams = self.trace_full(mirrors)
        return lit, [b["path"] for b in beams]

    def solved(self, mirrors):
        lit, shadow, _ = self.trace_full(mirrors)
        return len(lit) == len(self.targets) and not shadow

    def flip_groups(self):
        """Fixed mirrors grouped so twins flip together: list of lists of cells."""
        grouped, groups = set(), []
        for a, b in self.links:
            groups.append([a, b])
            grouped |= {a, b}
        for k in sorted(self.fixed):
            if k not in grouped:
                groups.append([k])
        return groups

    def setting(self, fixed, movers):
        s = dict(fixed)
        for pos, m in movers:
            s[pos] = m
        return s


def flip(m):
    return "\\" if m == "/" else "/"


def min_fixed_flips(board, movers):
    """Fewest taps on fixed mirrors (a twin pair is one tap) that solve the board with
    movers where they are. Returns (taps, setting) where taps lists one cell per tap."""
    groups = board.flip_groups()
    best = None
    for mask in range(1 << len(groups)):
        taps = [groups[i][0] for i in range(len(groups)) if (mask >> i) & 1]
        if best is not None and len(taps) >= len(best[0]):
            continue
        fixed = dict(board.fixed)
        for i in range(len(groups)):
            if (mask >> i) & 1:
                for cell in groups[i]:
                    fixed[cell] = flip(fixed[cell])
        if board.solved(board.setting(fixed, movers)):
            best = (taps, fixed)
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


def random_level_v2(rng, spec):
    """Levels for the newer worlds: twin mirrors, shadow crystals, bounce limits,
    prisms and circuit gates (no movers). Returns (level, fixed_goal, []) or None."""
    size = spec["size"]
    w = h = size
    for _ in range(200):
        cells = [(x, y) for y in range(h) for x in range(w)]
        rng.shuffle(cells)
        walls = set(cells[: int(len(cells) * spec["walls"])])
        free = [c for c in cells if c not in walls]
        fixed_goal = {free.pop(): rng.choice("/\\") for _ in range(spec["mirrors"])}
        n_beams = spec["beams"]
        colors = (["w"] + rng.sample(PRIMARIES, n_beams - 1)) if spec.get("prisms") else rng.sample(PRIMARIES, n_beams)
        emitters = [(free.pop(), rng.choice(list(DIRS.values())), BITS[c]) for c in colors]
        special = set(fixed_goal) | {e[0] for e in emitters}
        prisms, gates, targets, shadows = [], {}, {}, []

        def level_dict(fixed, links=(), max_bounces=0, opens=None):
            rows = ["".join("#" if (x, y) in walls else fixed.get((x, y), ".") for x in range(w)) for y in range(h)]
            tl = []
            for p_, c_ in targets.items():
                t = {"x": p_[0], "y": p_[1], "color": NAMES[c_]}
                if opens and p_ in opens:
                    t["opens"] = opens[p_]
                tl.append(t)
            d = {"rows": rows,
                 "emitters": [{"x": p_[0], "y": p_[1], "dir": INV_DIRS[d_], "color": NAMES[c_]} for p_, d_, c_ in emitters],
                 "targets": tl, "filters": [], "tints": [], "movers": []}
            if links:
                d["links"] = [[list(a), list(b)] for a, b in links]
            if shadows:
                d["shadows"] = [list(p_) for p_ in shadows]
            if max_bounces:
                d["max_bounces"] = max_bounces
            if prisms:
                d["prisms"] = [list(p_) for p_ in prisms]
            if gates:
                d["gates"] = [{"x": p_[0], "y": p_[1], "id": i_} for p_, i_ in gates.items()]
            return d

        ok = True
        if spec.get("prisms"):
            b = Board(level_dict(fixed_goal))
            white = b.trace_full(fixed_goal)[2][0]["path"]
            options = [p_ for p_, _ in white[:-1] if p_ not in special]
            if not options:
                continue
            pr = rng.choice(options)
            prisms.append(pr)
            special.add(pr)
        # Crystals at the end of every beam that doesn't end in a prism.
        b = Board(level_dict(fixed_goal))
        lit, shadow, beams = b.trace_once(fixed_goal, frozenset())
        leaves = [bm for bm in beams if not bm["split"]]
        for bm in leaves:
            path = bm["path"]
            if not path or bm["bounces"] < spec["bounces"]:
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
        opens = {}
        if spec.get("circuit"):
            # A gate on beam #2's path that crystal #1 opens.
            if len(leaves) < 2:
                continue
            path_b = leaves[1]["path"]
            options = [p_ for p_, _ in path_b[1:-1] if p_ not in special]
            if not options:
                continue
            g = rng.choice(options)
            gates[g] = "1"
            special.add(g)
            opens[leaves[0]["path"][-1][0]] = "1"
        max_b = max(bm["bounces"] for bm in leaves) if spec.get("deep") else 0
        goal_level = level_dict(fixed_goal, max_bounces=max_b, opens=opens)
        if not Board(goal_level).solved(fixed_goal):
            continue
        # Twin mirrors: pair up some fixed mirrors.
        links = []
        if spec.get("links"):
            keys = list(fixed_goal)
            rng.shuffle(keys)
            for i in range(min(spec["links"], len(keys) // 2)):
                links.append((keys[2 * i], keys[2 * i + 1]))
        # Shadow crystals on cells that wrong settings light up, never on the goal paths.
        if spec.get("shadows"):
            goal_cells = {p_ for bm in Board(goal_level).trace_full(fixed_goal)[2] for p_, _ in bm["path"]}
            touched = {}
            for _ in range(12):
                wrong = {k: rng.choice("/\\") for k in fixed_goal}
                for bm in Board(goal_level).trace_full(wrong)[2]:
                    for p_, _ in bm["path"]:
                        if p_ not in goal_cells and p_ not in special and p_ not in walls:
                            touched[p_] = touched.get(p_, 0) + 1
            if len(touched) < spec["shadows"]:
                continue
            for p_ in sorted(touched, key=lambda q: -touched[q])[: spec["shadows"]]:
                shadows.append(p_)
                special.add(p_)
        goal_level = level_dict(fixed_goal, links, max_b, opens)
        if not Board(goal_level).solved(fixed_goal):
            continue
        # Scramble by tapping (a twin pair flips together).
        start = dict(fixed_goal)
        board = Board(goal_level)
        for group in board.flip_groups():
            if rng.random() < 0.5:
                for cell in group:
                    start[cell] = flip(start[cell])
        level = level_dict(start, links, max_b, opens)
        board = Board(level)
        if board.solved(board.setting(board.fixed, [])):
            continue
        return level, fixed_goal, []
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
    {"name": "Twin Observatory", "intro": "Twin mirrors are linked: flip one and its twin flips too.", "v2": True, "curve": [
        S(5, 1, 3, .08, 1, 1, 2, links=1), S(5, 1, 4, .08, 2, 1, 2, links=1), S(6, 1, 5, .08, 2, 2, 3, links=2),
        S(6, 2, 5, .08, 1, 2, 3, links=2), S(6, 2, 6, .08, 2, 2, 4, links=2), S(6, 2, 6, .10, 2, 3, 4, links=3),
        S(7, 2, 7, .08, 2, 3, 5, links=3), S(7, 3, 7, .08, 1, 3, 5, links=3), S(7, 3, 8, .08, 2, 3, 6, links=3),
        S(7, 3, 9, .08, 2, 4, 7, links=4),
    ]},
    {"name": "Shadow Vault", "intro": "Shadow crystals must stay dark. Don't let any beam touch them.", "v2": True, "curve": [
        S(5, 1, 3, .08, 1, 1, 2, shadows=1), S(5, 1, 4, .08, 2, 1, 2, shadows=1), S(6, 1, 5, .08, 2, 2, 3, shadows=2),
        S(6, 2, 5, .08, 1, 2, 3, shadows=2), S(6, 2, 6, .08, 2, 2, 4, shadows=2), S(6, 2, 6, .10, 2, 3, 4, shadows=3),
        S(7, 2, 7, .08, 2, 3, 5, shadows=3, links=1), S(7, 3, 7, .08, 1, 3, 5, shadows=3), S(7, 3, 8, .08, 2, 3, 6, shadows=4),
        S(7, 3, 9, .08, 2, 4, 7, shadows=4, links=2),
    ]},
    {"name": "Deep Sea", "intro": "Light fades in the deep: beams can only bounce so many times.", "v2": True, "curve": [
        S(5, 1, 3, .08, 2, 1, 2, deep=True), S(5, 1, 4, .08, 2, 1, 3, deep=True), S(6, 1, 5, .08, 3, 2, 3, deep=True),
        S(6, 2, 5, .08, 2, 2, 3, deep=True), S(6, 2, 6, .08, 2, 2, 4, deep=True), S(6, 2, 6, .10, 3, 3, 4, deep=True),
        S(7, 2, 7, .08, 3, 3, 5, deep=True, shadows=1), S(7, 3, 7, .08, 2, 3, 5, deep=True), S(7, 3, 8, .08, 2, 3, 6, deep=True, links=1),
        S(7, 3, 9, .08, 2, 4, 7, deep=True, shadows=2),
    ]},
    {"name": "Prism Peaks", "intro": "Prisms split white light: red turns left, yellow goes straight, blue turns right.", "v2": True, "curve": [
        S(5, 1, 2, .06, 0, 1, 2, prisms=1), S(6, 1, 3, .06, 0, 1, 2, prisms=1), S(6, 1, 4, .06, 0, 2, 3, prisms=1),
        S(6, 1, 5, .06, 1, 2, 3, prisms=1), S(7, 2, 5, .06, 0, 2, 4, prisms=1), S(7, 1, 6, .06, 1, 3, 4, prisms=1),
        S(7, 2, 6, .06, 1, 3, 5, prisms=1, links=1), S(7, 2, 7, .06, 1, 3, 5, prisms=1, shadows=1), S(7, 2, 8, .06, 1, 3, 6, prisms=1),
        S(7, 3, 8, .06, 1, 4, 7, prisms=1, links=1),
    ]},
    {"name": "Circuit Temple", "intro": "Light one crystal to open the gate for another beam.", "v2": True, "curve": [
        S(5, 2, 3, .06, 0, 1, 2, circuit=True), S(6, 2, 4, .06, 1, 1, 3, circuit=True), S(6, 2, 5, .06, 1, 2, 3, circuit=True),
        S(6, 2, 5, .08, 1, 2, 4, circuit=True), S(6, 2, 6, .08, 1, 3, 4, circuit=True), S(7, 3, 6, .06, 1, 3, 5, circuit=True),
        S(7, 2, 7, .06, 2, 3, 5, circuit=True, links=1), S(7, 3, 7, .06, 1, 3, 5, circuit=True, shadows=1), S(7, 3, 8, .06, 1, 3, 6, circuit=True),
        S(7, 3, 9, .06, 2, 4, 7, circuit=True, links=2),
    ]},
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--tries", type=int, default=600)
    ap.add_argument("--regenerate-all", action="store_true",
                    help="also regenerate worlds that already exist in --out (changes existing levels!)")
    args = ap.parse_args()
    existing = {}
    if os.path.exists(args.out) and not args.regenerate_all:
        for w in json.load(open(args.out))["worlds"]:
            existing[w["name"]] = w
    rng = random.Random(args.seed)
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
        if world.get("v2"):
            rng = random.Random(args.seed * 1000 + wi)
        levels = []
        for spec in world["curve"]:
            n += 1
            best = None
            for _ in range(args.tries):
                made = random_level_v2(rng, spec) if world.get("v2") else random_level(rng, spec)
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
            extras = {k: spec[k] for k in ("filters", "tints", "movers", "portals", "links", "shadows", "deep", "prisms", "circuit") if k in spec}
            print(f"{world['name']:16} level {n:2}: {spec['size']}x{spec['size']}, {spec['beams']} beam(s), "
                  f"{spec['mirrors']} mirrors {extras}, par {par}, {count} solution(s)")
        worlds_out.append({"name": world["name"], "intro": world["intro"], "levels": levels})
    with open(args.out, "w") as f:
        json.dump({"worlds": worlds_out}, f, indent=2)
        f.write("\n")
    print(f"Wrote {n} levels to {args.out}")


if __name__ == "__main__":
    main()
