#!/usr/bin/env bash
# Tests scripts/lint/check-actor-isolation-warnings.sh against small logs (#630). No network.
# Run: scripts/lint/check-actor-isolation-warnings.test.sh
set -euo pipefail
CHECK="$(cd "$(dirname "$0")" && pwd)/check-actor-isolation-warnings.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

# case <name> <expected exit> <log content>
case_() {
  printf '%s\n' "$3" >"$work/$1.log"
  local got=0
  "$CHECK" "$work/$1.log" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$2" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected exit $2, got $got"
    fail=1
  fi
}

W='/src/Overgrove/A.swift:12:5: warning: call to main actor-isolated static method '\''help'\'' in a synchronous nonisolated context [#ActorIsolatedCall]'
case_ clean 0 'Compiling A.swift
** TEST SUCCEEDED **'
case_ warning 1 "$W"
case_ repeated-warning 1 "$W
$W"
case_ other-warning 0 '/src/A.swift:1:1: warning: variable '\''x'\'' was never used [#UnusedVariable]'
case_ note-only 0 '   |    `- note: main actor isolation inferred from conformance to protocol '\''View'\'''

got=0
"$CHECK" "$work/missing.log" >/dev/null 2>&1 || got=$?
if [[ "$got" == 2 ]]; then echo "ok   missing-log"; else echo "FAIL missing-log: expected exit 2, got $got"; fail=1; fi

# The same warning printed twice (xcodebuild repeats diagnostics) is listed once.
printf '%s\n%s\n' "$W" "$W" >"$work/dup.log"
lines=$("$CHECK" "$work/dup.log" 2>&1 >/dev/null | grep -c '^✋' || true)
if [[ "$lines" == 1 ]]; then echo "ok   listed-once"; else echo "FAIL listed-once: $lines lines"; fail=1; fi

if ((fail)); then echo "check-actor-isolation-warnings: FAILED"; exit 1; fi
echo "check-actor-isolation-warnings: all passed"
