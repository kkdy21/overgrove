#!/usr/bin/env bash
# Creates or updates labels from .github/labels.json.
#   scripts/github/sync-labels.sh            # create/update only
#   scripts/github/sync-labels.sh --prune    # also delete labels that are not in the file
# Requires: gh (logged in, repo scope), jq.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
REPO="${REPO:-kkdy21/overgrove}"
FILE=.github/labels.json

jq -c '.[]' "$FILE" | while IFS= read -r row; do
  name=$(jq -r .name <<<"$row"); color=$(jq -r .color <<<"$row"); desc=$(jq -r .description <<<"$row")
  gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" --force >/dev/null
  echo "label: $name"
done

if [[ "${1:-}" == "--prune" ]]; then
  wanted=$(jq -r '.[].name' "$FILE")
  gh label list --repo "$REPO" --limit 200 --json name --jq '.[].name' | while IFS= read -r existing; do
    if ! grep -Fxq "$existing" <<<"$wanted"; then
      gh label delete "$existing" --repo "$REPO" --yes >/dev/null
      echo "deleted: $existing"
    fi
  done
fi
