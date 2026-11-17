#!/usr/bin/env bash
# Downloads the images the Grok bots delivered on the art-incoming branch
# into art/<game>/incoming/ on this computer (without switching branches).
set -euo pipefail
cd "$(dirname "$0")/../.."
git fetch origin art-incoming
git ls-tree -r --name-only origin/art-incoming | grep '/incoming/' \
  | xargs git restore --source origin/art-incoming --worktree --
git ls-tree -r --name-only origin/art-incoming | grep '/incoming/'
echo "Done. Images are in art/<game>/incoming/."
