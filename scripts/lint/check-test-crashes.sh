#!/usr/bin/env bash
# Fails if a test can crash the test host instead of failing (#312). `try!` in a test or its fixtures turns an error
# into `swift_unexpectedError`: the whole host stops and the tests after it leave no result. Use `try` in a throwing
# test, `XCTUnwrap`, or a helper that calls `XCTFail` instead.
#
# Checks tracked Swift files under OvergroveTests/ only; comments are not exempt (keep the pattern out of them too).
#
# Usage:
#   scripts/lint/check-test-crashes.sh        # check the repository this script lives in
#   scripts/lint/check-test-crashes.sh DIR    # check another git work tree (used by the test)
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
status=0

while IFS= read -r -d '' path; do
  if matches=$(grep -nE 'try!' "$root/$path"); then
    while IFS= read -r line; do
      echo "✋ $path:${line%%:*}: try! crashes the test host on failure" >&2
    done <<<"$matches"
    status=1
  fi
done < <(git -C "$root" ls-files -z -- 'OvergroveTests/*.swift')

if [[ $status -ne 0 ]]; then
  echo "Use try in a throwing test, XCTUnwrap, or a helper that calls XCTFail (#312)." >&2
  exit 1
fi
echo "ok  no try! in tests"
