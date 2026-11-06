#!/bin/sh
# Regenerates design/mockups/*.svg and *.png from screens.py.
# Optional design tool — not used by the app or CI. Needs macOS, Python 3 with fontTools, and rsvg-convert:
#   python3 -m venv design/mockups/generator/.venv
#   design/mockups/generator/.venv/bin/pip install fonttools
#   brew install librsvg
# Usage: ./render.sh [screen ...]   (default: all screens)
set -eu
cd "$(dirname "$0")"
PY=./.venv/bin/python
OUT=..
# Static SF Pro / SF Mono weights for the renderer (local only, git-ignored).
$PY mkfonts.py
export PANGOCAIRO_BACKEND=fc
export FONTCONFIG_FILE="$(pwd)/.fonts/fonts.conf"
$PY screens.py "$OUT" "$@" | tail -1
for f in "$OUT"/*.svg; do
  name=$(basename "$f" .svg)
  if [ "$#" -gt 0 ]; then
    case " $* " in *" ${name%-light}"*|*" ${name%-dark}"*) ;; *) continue ;; esac
  fi
  case "$name" in
    main-window-*) width=2880 ;;   # README hero: 2x
    *) width=1440 ;;
  esac
  rsvg-convert -w "$width" "$f" -o "$OUT/$name.png"
done
$PY pngopt.py "$OUT"/*.png >/dev/null
