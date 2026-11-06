#!/bin/sh
# Regenerates design/mockups/*.svg and *.png from screens.py.
# Optional design tool — not used by the app or CI. Needs Python 3, fontTools (text measuring), and rsvg-convert.
#   python3 -m venv design/mockups/generator/.venv
#   design/mockups/generator/.venv/bin/pip install fonttools
#   brew install librsvg
set -eu
cd "$(dirname "$0")"
PY=./.venv/bin/python
OUT=..
$PY screens.py "$OUT" "$@" | tail -1
for f in "$OUT"/*.svg; do rsvg-convert -w 1280 "$f" -o "${f%.svg}.png"; done
$PY pngopt.py "$OUT"/*.png >/dev/null
