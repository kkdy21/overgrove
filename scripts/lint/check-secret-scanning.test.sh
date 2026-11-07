#!/usr/bin/env bash
# Runs the secret-scanning controls for real (SEC-T18-01, SEC-T18-02, #95). No network.
#
#   - the static wiring check (scripts/lint/check-secret-scanning.sh) on this repository and on broken copies
#   - both hooks refuse to run when gitleaks is not on PATH (no gitleaks needed for this part)
#   - with gitleaks: the repository's .gitleaks.toml flags personal home paths and lets placeholders through, the
#     real pre-commit hook blocks a staged home path, and the real pre-push hook blocks a pushed one
#
# gitleaks runs in the CI `gitleaks` job (OVERGROVE_REQUIRE_GITLEAKS=1 there). Elsewhere, the gitleaks part is
# skipped with a notice when gitleaks is not installed.
#
# Personal paths are assembled at runtime so this file never contains one (it is scanned like any other).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
CHECK="$here/check-secret-scanning.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
home_path="/Us""ers/alice-example-0/projects/secret-notes.txt"
placeholder_path="/Us""ers/runner/work/overgrove/overgrove"

pass() { echo "ok   $1"; }
failed() {
  echo "FAIL $1"
  fail=1
}

# --- Static wiring check -------------------------------------------------------------------------------------------

if "$CHECK" >/dev/null; then pass "wiring: this repository"; else failed "wiring: this repository"; fi

# broken <name> <file> <sed expression>: a copy of the wiring with one change must be rejected.
broken() {
  local dir="$work/static-$1"
  mkdir -p "$dir/.githooks" "$dir/.github/workflows" "$dir/scripts"
  cp "$repo_root/.githooks/pre-commit" "$repo_root/.githooks/pre-push" "$dir/.githooks/"
  cp "$repo_root/.github/workflows/secret-scan.yml" "$dir/.github/workflows/"
  cp "$repo_root/scripts/bootstrap.sh" "$dir/scripts/"
  cp "$repo_root/.gitleaks.toml" "$dir/"
  sed -E -i.bak "$3" "$dir/$2" && rm -f "$dir/$2.bak"
  if "$CHECK" "$dir" >/dev/null 2>&1; then failed "wiring rejects $1"; else pass "wiring rejects $1"; fi
}
broken pre-commit-no-scan .githooks/pre-commit 's/gitleaks git --pre-commit --staged/true/'
broken pre-commit-skips-without-gitleaks .githooks/pre-commit 's/^  exit 1$/  exit 0/'
broken pre-push-no-scan .githooks/pre-push 's/gitleaks git /true /'
broken ci-no-pull-request .github/workflows/secret-scan.yml '/^  pull_request:/d'
broken no-home-path-rule .gitleaks.toml 's/personal-home-path/other-rule/'
broken no-default-rules .gitleaks.toml 's/useDefault = true/useDefault = false/'

# --- A scratch repository with the real hooks ----------------------------------------------------------------------

# scratch <name>: a repository on a feature branch whose hooks are this repository's hooks.
scratch() {
  local dir="$work/$1"
  git init -q -b test/95-scratch "$dir"
  mkdir -p "$dir/.githooks" "$dir/scripts/lint"
  cp "$repo_root/.githooks/pre-commit" "$repo_root/.githooks/pre-push" "$dir/.githooks/"
  cp "$repo_root/scripts/lint/check-forbidden-apis.sh" "$dir/scripts/lint/"
  cp "$repo_root/.gitleaks.toml" "$dir/"
  git -C "$dir" config user.name Test
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config commit.gpgsign false
  # Setup commits skip the hooks on purpose (the hooks are what is under test).
  git -C "$dir" add -A
  git -C "$dir" -c core.hooksPath=/dev/null commit -q -m setup
  echo "$dir"
}

# run_hook <dir> <hook> [stdin]: runs the hook as git would, from the repository, with the given PATH.
run_hook() {
  local dir=$1 hook=$2 input=${3:-}
  (cd "$dir" && printf '%s' "$input" | PATH="$hook_path" bash ".githooks/$hook" >/dev/null 2>&1)
}

# Without gitleaks the hooks must fail closed. A PATH with git and the shell tools but no gitleaks.
no_gitleaks="$work/no-gitleaks-bin"
mkdir -p "$no_gitleaks"
for tool in git bash env sed awk grep cat dirname printf; do
  found=$(command -v "$tool" || true)
  [[ -n "$found" && "$found" == /* ]] && ln -sf "$found" "$no_gitleaks/$tool"
done
if PATH="$no_gitleaks" command -v gitleaks >/dev/null 2>&1; then
  failed "test setup: gitleaks still on the restricted PATH"
else
  dir=$(scratch no-gitleaks)
  hook_path="$no_gitleaks"
  printf 'clean\n' >"$dir/clean.txt"
  git -C "$dir" add clean.txt
  if run_hook "$dir" pre-commit; then failed "pre-commit fails without gitleaks"; else pass "pre-commit fails without gitleaks"; fi
  sha=$(git -C "$dir" rev-parse HEAD)
  if run_hook "$dir" pre-push "refs/heads/test/95-scratch $sha refs/heads/test/95-scratch 0000000000000000000000000000000000000000
"; then failed "pre-push fails without gitleaks"; else pass "pre-push fails without gitleaks"; fi
fi

# --- With gitleaks -------------------------------------------------------------------------------------------------

if ! command -v gitleaks >/dev/null 2>&1; then
  if [[ "${OVERGROVE_REQUIRE_GITLEAKS:-}" == "1" ]]; then
    failed "gitleaks is required (OVERGROVE_REQUIRE_GITLEAKS=1) but not installed"
  else
    echo "skip gitleaks checks: gitleaks is not installed (they run in the CI gitleaks job)"
  fi
  exit $fail
fi
hook_path="$PATH"

# SEC-T18-02: the repository's rules on plain files.
scan_dir() {
  local dir="$work/scan-$1"
  mkdir -p "$dir"
  printf 'config = "%s"\n' "$2" >"$dir/sample.txt"
  gitleaks dir --no-banner --redact --exit-code 1 --config "$repo_root/.gitleaks.toml" "$dir" >/dev/null 2>&1
}
if scan_dir home "$home_path"; then failed "rule flags a /Users home path"; else pass "rule flags a /Users home path"; fi
if scan_dir linux-home "/ho""me/bob-example-0/.ssh/config"; then failed "rule flags a /home path"; else pass "rule flags a /home path"; fi
if scan_dir one-letter "/Us""ers/a/notes.txt"; then failed "rule flags a one-letter user name"; else pass "rule flags a one-letter user name"; fi
if scan_dir placeholder "$placeholder_path"; then pass "rule allows placeholder homes"; else failed "rule allows placeholder homes"; fi
if scan_dir linux-runner "/ho""me/runner/work/overgrove"; then pass "rule allows the CI runner home"; else failed "rule allows the CI runner home"; fi
if scan_dir example "~/dev/overgrove"; then pass "rule allows ~/ paths"; else failed "rule allows ~/ paths"; fi

# SEC-T18-01: the real pre-commit hook on staged changes.
dir=$(scratch pre-commit)
printf 'notes = "%s"\n' "$home_path" >"$dir/leak.txt"
git -C "$dir" add leak.txt
if run_hook "$dir" pre-commit; then failed "pre-commit blocks a staged home path"; else pass "pre-commit blocks a staged home path"; fi
git -C "$dir" rm -q --cached leak.txt
printf 'clean\n' >"$dir/clean.txt"
git -C "$dir" add clean.txt
if run_hook "$dir" pre-commit; then pass "pre-commit allows a clean change"; else failed "pre-commit allows a clean change"; fi

# SEC-T18-01: the real pre-push hook on the commits being pushed (a new branch: everything not on a remote).
dir=$(scratch pre-push)
zero=0000000000000000000000000000000000000000
clean_sha=$(git -C "$dir" rev-parse HEAD)
if run_hook "$dir" pre-push "refs/heads/test/95-scratch $clean_sha refs/heads/test/95-scratch $zero
"; then pass "pre-push allows clean commits"; else failed "pre-push allows clean commits"; fi
printf 'notes = "%s"\n' "$home_path" >"$dir/leak.txt"
git -C "$dir" add leak.txt
git -C "$dir" -c core.hooksPath=/dev/null commit -q -m "leak for the test"
leak_sha=$(git -C "$dir" rev-parse HEAD)
if run_hook "$dir" pre-push "refs/heads/test/95-scratch $leak_sha refs/heads/test/95-scratch $zero
"; then failed "pre-push blocks a pushed home path"; else pass "pre-push blocks a pushed home path"; fi
if run_hook "$dir" pre-push "refs/heads/main $clean_sha refs/heads/main $zero
"; then failed "pre-push blocks pushes to main"; else pass "pre-push blocks pushes to main"; fi

exit $fail
