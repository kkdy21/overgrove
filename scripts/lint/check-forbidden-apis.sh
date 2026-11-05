#!/usr/bin/env bash
# Fails if Swift files outside the allowed directories create processes or use a shell.
#
# Rule (docs/README.md §2.2, threat T9/T13): only Overgrove/Execution/ may create processes.
# Test support code that runs fixture scripts lives in OvergroveTests/Support/ and is also allowed.
#
# Usage:
#   scripts/lint/check-forbidden-apis.sh                 # scan every tracked *.swift file
#   scripts/lint/check-forbidden-apis.sh FILE [FILE...]  # scan given files (used by hooks)
#   echo "$content" | scripts/lint/check-forbidden-apis.sh --stdin PATH   # scan content as if it were PATH
set -euo pipefail

ALLOWED_PREFIXES=("Overgrove/Execution/" "OvergroveTests/Support/")
# Process( / NSTask / posix_spawn / popen( / bare system( (not `.system(` like Font.system) / explicit shells
PATTERN='(^|[^A-Za-z0-9_])(Process[[:space:]]*\(|NSTask|posix_spawn|popen[[:space:]]*\()|(^|[^A-Za-z0-9_.])system[[:space:]]*\(|/bin/(ba|z|da)?sh([^A-Za-z]|$)'

is_allowed() {
  local path="${1#./}"
  for p in "${ALLOWED_PREFIXES[@]}"; do
    [[ "$path" == "$p"* ]] && return 0
  done
  return 1
}

report() { echo "✋ $1: process creation / shell use is only allowed in ${ALLOWED_PREFIXES[*]}" >&2; }

status=0
if [[ "${1:-}" == "--stdin" ]]; then
  path="${2:?--stdin needs a PATH}"
  [[ "$path" == *.swift ]] || exit 0
  is_allowed "$path" && exit 0
  if matches=$(grep -nE "$PATTERN"); then
    report "$path"; printf '%s\n' "$matches" | sed 's/^/    /' >&2; status=1
  fi
  exit $status
fi

if [[ $# -gt 0 ]]; then
  files=("$@")
else
  files=()
  while IFS= read -r -d '' f; do files+=("$f"); done < <(git ls-files -z -- '*.swift')
fi

[[ ${#files[@]} -eq 0 ]] && exit 0   # bash 3.2 + set -u: empty arrays are "unbound"

for f in "${files[@]}"; do
  [[ "$f" == *.swift && -f "$f" ]] || continue
  is_allowed "$f" && continue
  if matches=$(grep -nE "$PATTERN" "$f"); then
    report "$f"; printf '%s\n' "$matches" | sed 's/^/    /' >&2; status=1
  fi
done
exit $status
