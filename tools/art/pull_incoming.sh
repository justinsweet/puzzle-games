#!/usr/bin/env bash
# Downloads the images the Grok bots delivered into art/<game>/incoming/ on this
# computer, without switching branches. Each bot delivers on its own branch:
#   art-incoming-art (Art Bot), art-incoming-characters (Character Bot),
#   art-incoming-promo (Promo Bot), plus the older shared art-incoming branch.
set -euo pipefail
cd "$(dirname "$0")/../.."
branches=$(git ls-remote --heads origin 'art-incoming*' | sed 's#.*refs/heads/##')
if [ -z "$branches" ]; then
  echo "No bot deliveries yet."
  exit 0
fi
for b in $branches; do
  git fetch -q origin "$b"
  files=$(git ls-tree -r --name-only "origin/$b" | grep '/incoming/' || true)
  if [ -n "$files" ]; then
    echo "$files" | xargs git restore --source "origin/$b" --worktree --
    echo "From $b:"
    echo "$files" | sed 's/^/  /'
  fi
done
echo "Done. Images are in art/<game>/incoming/."
