#!/usr/bin/env bash
# Tests scripts/github/pr-toolchain-check.sh (#507) with synthetic PR bodies and file lists. No network.
# Run: scripts/github/pr-toolchain-check.test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

printf 'jobs:\n  build-test:\n    env:\n      XCODE_MAJOR: "26"\n' >"$work/ci.yml"

app_files=$'Overgrove/App/AppState.swift\ndocs/README.md'
doc_files=$'docs/README.md\nscripts/bootstrap.sh'

body() { # body <toolchain line, or "-" for no line>
  printf 'Closes #1\n\n## How it was verified\n\n- [x] `xcodebuild test` passes locally\n'
  [[ "$1" == "-" ]] || printf -- '%s\n' "$1"
  printf '\n## Checklist\n'
}

# check <name> <draft> <files> <body> <expected: "none" or text the warning must contain>
check() {
  local out code
  set +e
  out=$(BODY="$4" DRAFT="$2" bash "$here/pr-toolchain-check.sh" "$work/ci.yml" <<<"$3" 2>&1)
  code=$?
  set -e
  if [[ $code -ne 0 ]]; then
    echo "FAIL $1: exit $code (it only warns, so it always exits 0)"
    fail=1
  elif [[ "$5" == none && "$out" == *"::warning"* ]]; then
    echo "FAIL $1: unexpected warning: $out"
    fail=1
  elif [[ "$5" != none && ("$out" != *"::warning"* || "$out" != *"$5"*) ]]; then
    echo "FAIL $1: expected a warning with \"$5\", got: ${out:-(nothing)}"
    fail=1
  else
    echo "ok   $1"
  fi
}

filled='- Local toolchain: Xcode 26.1 (17B55), macOS 26.1'
template='- Local toolchain: <!-- e.g. Xcode 26.1 (17B55), macOS 26.1 -->'

check "ready app PR with CI's Xcode major: no warning"  false "$app_files" "$(body "$filled")" none
check "draft PR: not checked yet"                       true  "$app_files" "$(body "$template")" none
check "no app code touched: not needed"                 false "$doc_files" "$(body "$template")" none
check "line left as the template comment"               false "$app_files" "$(body "$template")" "empty"
check "line removed"                                    false "$app_files" "$(body -)" "Local toolchain"
check "line names no Xcode version"                     false "$app_files" "$(body '- Local toolchain: macOS 26.1')" \
  "Xcode"
check "another Xcode major than CI's"                   false "$app_files" \
  "$(body '- Local toolchain: Xcode 25.4 (16F6), macOS 15.5')" "Xcode 26"
check "Xcode 260 is not Xcode 26"                       false "$app_files" \
  "$(body '- Local toolchain: Xcode 260.1, macOS 26.1')" "Xcode 26"
check "test-only change counts as app code"             false "OvergroveTests/FooTests.swift" "$(body "$template")" \
  "empty"
check "project file change counts as app code"          false "Overgrove.xcodeproj/project.pbxproj" \
  "$(body "$template")" "empty"
check "CRLF body (from the web editor)"                 false "$app_files" "$(body "$filled" | sed 's/$/\r/')" none
# PR text is untrusted: a crafted value must not inject a workflow command into the warning.
check "a crafted value cannot add a workflow command"   false "$app_files" \
  "$(body $'- Local toolchain: Xcode 25%0A::error::forged')" "Xcode 26"
out=$(BODY="$(body $'- Local toolchain: Xcode 25%0A::error::forged')" DRAFT=false \
  bash "$here/pr-toolchain-check.sh" "$work/ci.yml" <<<"$app_files" 2>&1)
if [[ "$out" == *$'\n::error'* || "$out" == "::error"* ]]; then
  echo "FAIL a crafted value cannot add a workflow command: $out"
  fail=1
else
  echo "ok   a crafted value stays inside the warning"
fi

printf 'jobs: {}\n' >"$work/no-major.yml"
set +e
out=$(BODY="$(body "$filled")" DRAFT=false bash "$here/pr-toolchain-check.sh" "$work/no-major.yml" <<<"$app_files" 2>&1)
code=$?
set -e
if [[ $code -eq 0 && "$out" == *"::warning"*"XCODE_MAJOR"* ]]; then
  echo "ok   CI's Xcode major unreadable: warns and still exits 0"
else
  echo "FAIL CI's Xcode major unreadable: exit $code, output: $out"
  fail=1
fi

exit $fail
