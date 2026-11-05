#!/usr/bin/env bash
# One-time local setup for contributors.
#  - Installs the repository Git hooks (core.hooksPath=.githooks)
#  - Checks the toolchain: git >= 2.36, gitleaks, Xcode, swift-format, gh (optional)
# Safe to re-run.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; missing=1; }
missing=0

echo "Git hooks"
git config core.hooksPath .githooks
chmod +x .githooks/* scripts/*.sh scripts/lint/*.sh scripts/github/*.sh 2>/dev/null || true
ok "core.hooksPath=.githooks (pre-commit, prepare-commit-msg, commit-msg, pre-push)"

echo "Toolchain"
git_ver=$(git --version | sed -E 's/^git version ([0-9]+\.[0-9]+).*/\1/')
if printf '%s\n%s\n' "2.36" "$git_ver" | sort -V -C; then ok "git $git_ver"; else bad "git $git_ver is older than 2.36"; fi

if command -v gitleaks >/dev/null 2>&1; then ok "gitleaks $(gitleaks version)"; else bad "gitleaks not found — brew install gitleaks (required by the commit and push hooks)"; fi

dev_dir=$(xcode-select -p 2>/dev/null || true)
if [[ "$dev_dir" == *Xcode*.app* ]]; then
  if xcodebuild -version >/dev/null 2>&1; then ok "$(xcodebuild -version | head -1) at $dev_dir"
  else warn "Xcode is selected but not ready. Run: sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch"; fi
elif [[ -d /Applications/Xcode.app ]]; then
  warn "Command Line Tools are selected. For Phase 3 run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
else
  warn "Xcode not found. It is required to build the app (Phase 3+)."
fi

if swift format --version >/dev/null 2>&1; then ok "swift-format $(swift format --version)"; else warn "swift format not available (ships with the Swift toolchain / Xcode)"; fi

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then ok "gh logged in (optional)"; else warn "gh installed but not logged in (optional): gh auth login"; fi
else
  warn "gh not installed (optional: issues panel and maintainer scripts)"
fi

echo
if [[ $missing -eq 0 ]]; then echo "Ready. Next: read CONTRIBUTING.md and pick an issue."; else echo "Fix the ✗ items above."; exit 1; fi
