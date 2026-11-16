# puzzle-games

Our mobile puzzle games, built with Godot 4.

| Folder | What's in it |
| --- | --- |
| `shared/addons/studio_core/` | Code every game reuses: ads, (later) saves, purchases, menus. **Edit shared code here.** |
| `games/tilt/` | Tilt, game #1 (a Godot project: open `games/tilt/project.godot`) |
| `games/beam/` | Beam, game #2 (open `games/beam/project.godot`) |
| `tools/levelgen/` | Level generators and solvers |
| `tools/sync_shared.sh` | Copies `shared/addons/studio_core` into each game. Run after changing shared code. |
| `art/` | Source art and style guides (stored with Git LFS) |
| `docs/` | Notes and design docs |

## First-time setup (each computer)

```bash
brew install git-lfs
git lfs install
```

## Running Tilt

1. Open Godot, click **Import**, choose `games/tilt/project.godot`.
2. Press **F5** (or the Play button).
3. Swipe with the mouse (click, drag, release) or use the arrow keys / WASD.
   Keys: `Z` undo, `R` restart, `H` hint, `N` next level, `P` previous level.

## Running Beam

Import `games/beam/project.godot` the same way. Click or tap a mirror to flip it.
Keys: `Z` undo, `R` restart, `H` hint, `N` next level, `P` previous level.

## Making new levels

```bash
python3 tools/levelgen/tilt_levelgen.py --out games/tilt/levels/levels.json
python3 tools/levelgen/beam_levelgen.py --out games/beam/levels/levels.json
```

Each generator only keeps levels its solver can beat, and records the fewest moves (par).
