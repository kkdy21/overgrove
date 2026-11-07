#!/usr/bin/env bash
# Tests scripts/lint/check-test-crashes.sh against throwaway git repositories (#312). No network.
# Run: scripts/lint/check-test-crashes.test.sh
set -euo pipefail
CHECK="$(cd "$(dirname "$0")" && pwd)/check-test-crashes.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

# case <name> <expected exit 0|1> <file path> <file content>
case_() {
  local repo="$work/$1"
  git init -q "$repo"
  mkdir -p "$repo/$(dirname "$3")"
  printf '%s\n' "$4" >"$repo/$3"
  git -C "$repo" add -A
  local got=0
  "$CHECK" "$repo" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$2" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected exit $2, got $got"
    fail=1
  fi
}

case_ throwing-test 0 OvergroveTests/A/ATests.swift 'func testA() throws { _ = try parse() }'
case_ unwrap 0 OvergroveTests/A/ATests.swift 'let x = try XCTUnwrap(value)'
case_ try-bang 1 OvergroveTests/A/ATests.swift 'let listing = try! PatchParser.parse(data)'
case_ try-bang-nested 1 OvergroveTests/Support/Fixtures.swift '    return .patch(try! parse(x))'
case_ app-code-not-checked 0 Overgrove/App/A.swift 'let x = try! parse()'
case_ not-swift 0 OvergroveTests/notes.md 'try! is banned'

# Untracked files are not checked.
repo="$work/untracked"
git init -q "$repo"
mkdir -p "$repo/OvergroveTests"
printf 'try! x\n' >"$repo/OvergroveTests/New.swift"
if "$CHECK" "$repo" >/dev/null 2>&1; then echo "ok   untracked-ignored"; else echo "FAIL untracked-ignored"; fail=1; fi

# The real repository passes.
if "$CHECK" >/dev/null; then echo "ok   this-repository"; else echo "FAIL this-repository"; fail=1; fi

exit $fail
