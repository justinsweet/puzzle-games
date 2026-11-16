#!/usr/bin/env bash
# Copies shared/addons/studio_core into every Godot game under games/.
# Always edit the shared code in shared/addons/studio_core, then run this script.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for game in "$ROOT"/games/*/; do
  [ -f "$game/project.godot" ] || continue
  mkdir -p "$game/addons"
  rsync -a --delete "$ROOT/shared/addons/studio_core/" "$game/addons/studio_core/"
  echo "Synced studio_core -> ${game#"$ROOT"/}"
done
