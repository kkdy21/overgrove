#!/usr/bin/env bash
# Checks that secret scanning is wired into all three stages (docs/design/security-review.md T18, #95).
#
#   SEC-T18-01  pre-commit scans the staged changes, pre-push scans the commits being pushed, CI scans PRs and main;
#               both hooks refuse to run without gitleaks; bootstrap installs the hooks
#   SEC-T18-02  .gitleaks.toml keeps the default rules and the personal home-path rule
#
# Static only: it reads the files. scripts/lint/check-secret-scanning.test.sh runs the hooks and the rules for real.
#
# Usage:
#   scripts/lint/check-secret-scanning.sh        # check this repository
#   scripts/lint/check-secret-scanning.sh DIR    # check another tree
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
status=0

report() {
  echo "✋ $1" >&2
  status=1
}

# require <file> <extended regex> <message>
require() {
  if [[ ! -f "$root/$1" ]]; then
    report "missing $1"
  elif ! grep -qE "$2" "$root/$1"; then
    report "$1: $3"
  fi
}

require .githooks/pre-commit 'gitleaks git --pre-commit --staged' "does not scan the staged changes with gitleaks"
require .githooks/pre-commit 'command -v gitleaks' "does not check that gitleaks is installed"
require .githooks/pre-push 'gitleaks git ' "does not scan the pushed commits with gitleaks"
require .githooks/pre-push 'command -v gitleaks' "does not check that gitleaks is installed"
require scripts/bootstrap.sh 'core\.hooksPath \.githooks' "does not install the repository hooks"
require .github/workflows/secret-scan.yml 'name: gitleaks' "has no job named gitleaks (the required check)"
require .github/workflows/secret-scan.yml 'gitleaks git ' "does not run gitleaks git"
require .github/workflows/secret-scan.yml 'pull_request:' "does not run on pull requests"
require .gitleaks.toml 'useDefault[[:space:]]*=[[:space:]]*true' "does not keep the default gitleaks rules"
require .gitleaks.toml 'id[[:space:]]*=[[:space:]]*"personal-home-path"' "has no personal home-path rule"

# A hook that finds gitleaks missing must stop, not skip the scan.
for hook in pre-commit pre-push; do
  file="$root/.githooks/$hook"
  [[ -f "$file" ]] || continue
  if ! awk '/command -v gitleaks/ { guard = 1 } guard && /exit 1/ { found = 1 } END { exit found ? 0 : 1 }' "$file"; then
    report ".githooks/$hook: continues without gitleaks instead of failing"
  fi
done

if [[ $status -eq 0 ]]; then
  echo "ok  secret scanning: pre-commit, pre-push and CI run gitleaks; home-path rule present"
fi
exit $status
