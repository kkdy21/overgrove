#!/usr/bin/env bash
# Renders the macOS AppIcon PNG set from design/icon/*.svg (iconography.md §6.1, #38).
#
#   scripts/render-app-icon.sh            regenerate Overgrove/Resources/Assets.xcassets/AppIcon.appiconset
#   scripts/render-app-icon.sh --check    fail if the committed set differs from a fresh render (CI)
#   scripts/render-app-icon.sh --rsvg     cross-check with rsvg-convert into build/appicon-rsvg/ (not committed)
#
# The committed set always comes from the default renderer (WebKit, built into macOS; scripts/icon/render-app-icon.swift),
# so --check can reproduce it without any extra tool (ADR-0006). rsvg-convert (Homebrew librsvg) is optional and only
# writes a separate folder for comparison; its anti-aliasing differs slightly from WebKit's.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  "")      exec swift scripts/icon/render-app-icon.swift ;;
  --check) exec swift scripts/icon/render-app-icon.swift --check ;;
  --rsvg)
    command -v rsvg-convert >/dev/null || { echo "error: rsvg-convert not found (brew install librsvg)" >&2; exit 1; }
    out=build/appicon-rsvg
    mkdir -p "$out"
    # name:pixels:source, the same table as scripts/icon/render-app-icon.swift.
    for slot in \
      icon_16x16:16:app-icon-small icon_16x16@2x:32:app-icon-small icon_32x32:32:app-icon-small \
      icon_32x32@2x:64:app-icon icon_128x128:128:app-icon icon_128x128@2x:256:app-icon \
      icon_256x256:256:app-icon icon_256x256@2x:512:app-icon icon_512x512:512:app-icon \
      icon_512x512@2x:1024:app-icon; do
      IFS=: read -r name pixels source <<< "$slot"
      rsvg-convert -w "$pixels" -h "$pixels" "design/icon/$source.svg" -o "$out/$name.png"
    done
    echo "wrote 10 PNGs to $out (for comparison only)"
    ;;
  *) echo "usage: $0 [--check | --rsvg]" >&2; exit 2 ;;
esac
