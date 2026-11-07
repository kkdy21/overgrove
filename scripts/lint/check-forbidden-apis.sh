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
# - the `Process` type in any form (`Process(`, `Process.run`, `: Process`), NSTask, NSUserUnixTask, posix_spawn, popen(
# - bare system( / exec*( / fork( / vfork( (not `.system(` like Font.system)
# - any explicit shell under /bin (sh, bash, zsh, dash, ksh, csh, tcsh, fish, ...)
# `ProcessInfo`, `ProcessRunner`, `ProcessRequest`, ... are other identifiers and do not match.
PATTERN='(^|[^A-Za-z0-9_])(Process([^A-Za-z0-9_]|$)|NSTask|NSUserUnixTask|posix_spawn|popen[[:space:]]*\()|(^|[^A-Za-z0-9_.])(system|exec[lv]p?e?|fork|vfork)[[:space:]]*\(|/bin/[a-z]*sh([^A-Za-z]|$)'

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
  # A failing `git ls-files` must not look like "no files, nothing to report" (review of #206).
  list=$(mktemp)
  trap 'rm -f "$list"' EXIT
  if ! git ls-files -z -- '*.swift' > "$list"; then
    echo "check-forbidden-apis: git ls-files failed; cannot list Swift files" >&2
    exit 2
  fi
  while IFS= read -r -d '' f; do files+=("$f"); done < "$list"
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
