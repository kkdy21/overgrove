#!/usr/bin/env bash
# Fails if an xcodebuild log has a `[#ActorIsolatedCall]` warning (#630).
#
# The local toolchain (Xcode 27, Swift 6.4) reports a call to a main-actor method from a nonisolated context, such as
# a static helper of a SwiftUI `View` called from a test or a pure model, as a warning that neither
# SWIFT_TREAT_WARNINGS_AS_ERRORS nor `-Werror ActorIsolatedCall` turns into an error. CI's Xcode 26 (Swift 6.3) reports
# the same call as an error. Run this on the log of the local full test run before pushing, so the error shows up here
# instead of in CI's build-test.
#
# Usage:
#   xcodebuild test ... 2>&1 | tee xcodebuild.log
#   scripts/lint/check-actor-isolation-warnings.sh xcodebuild.log
#
# Exit codes: 0 no such warning, 1 at least one (each listed once), 2 the log could not be read.
set -euo pipefail

log="${1:-}"
if [[ -z "$log" || ! -r "$log" ]]; then
  echo "usage: $0 <xcodebuild log>" >&2
  exit 2
fi

got=0
matches=$(grep -E ': warning: .*\[#ActorIsolatedCall\]' "$log" | sed -E 's/^[[:space:]]+//' | sort -u) || got=$?
case "$got" in
  0)
    while IFS= read -r line; do echo "✋ $line" >&2; done <<<"$matches"
    echo "Xcode 26 in CI reports these as errors. Mark the helper \`nonisolated static\` or move it out of the View (#630)." >&2
    exit 1 ;;
  1) echo "ok  no [#ActorIsolatedCall] warnings" ;;
  *) echo "✋ $log: could not be read" >&2; exit 2 ;;
esac
