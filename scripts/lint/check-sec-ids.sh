#!/usr/bin/env bash
# Checks that test IDs are defined once (#282). Parallel PRs picked the same new number three times
# (SEC-T15-08, -11, -15); reviewers caught each by hand.
#
#   SEC IDs    defined once, as `  - SEC-T<n>-<id> (` items of the **검증** list in docs/design/threats/T<n>.md (#457)
#              - no ID is defined twice, and each is defined in its own threat's file
#              - new IDs are `SEC-T<n>-<issue>-<k>` (issue number of 3+ digits, then a running number), so parallel PRs
#                cannot pick the same one; two-digit IDs from before #457 must be in scripts/lint/sec-ids-legacy.txt
#              - every SEC ID mentioned in security-review.md, the threat files, OvergroveTests (`SEC-T4-01`,
#                `SEC-T4-01/02`, `SEC-T<n>-<issue>-<k>`, `testSECT4_01`, `testSECT<n>_<issue>_<k>`), scripts/, or .github/ is
#                defined (this script's test, whose fixtures are made up, is skipped)
#   PAR-*      each row ID of docs/architecture/parsing-spec.md's tables appears in one row only
#   E<n>       each experiment row of security-review.md §4.1 appears once
#   PERF-nn    defined once in docs/performance/benchmark-plan.md §3's table; every PERF ID or `test_PERF_nn` name in
#              docs/, OvergroveTests, scripts/, or .github/ is defined (#288)
#
# Plain bash, grep and awk: runs in CI (macOS) and locally without extra tools.
#
# Usage:
#   scripts/lint/check-sec-ids.sh        # check this repository
#   scripts/lint/check-sec-ids.sh DIR    # check another tree (used by the test)
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
review="$root/docs/design/security-review.md"
parsing="$root/docs/architecture/parsing-spec.md"
status=0

report() {
  echo "✋ $1" >&2
  status=1
}

[[ -f "$review" ]] || { report "missing docs/design/security-review.md"; exit 1; }
threats="$root/docs/design/threats"
legacy_file="$root/scripts/lint/sec-ids-legacy.txt"
[[ -d "$threats" ]] || { report "missing docs/design/threats/"; exit 1; }

# "<threat> <id>" for every item of a **검증** list; the threat comes from the file name (T9.md).
definitions=$(for file in "$threats"/T*.md; do
  section=$(basename "$file" .md); section="${section#T}"
  awk -v section="$section" '
    /^- \*\*검증\*\*/ { inside = 1; next }
    /^- \*\*/ { inside = 0 }
    inside && match($0, /^  - SEC-T[0-9]+-[0-9]+(-[0-9]+)? \(/) {
      id = substr($0, 5, RLENGTH - 6)
      print section, id
    }' "$file"
done)

while read -r id; do
  [[ -n "$id" ]] && report "threats: $id is defined more than once on 검증 lists"
done < <(awk '{ print $2 }' <<<"$definitions" | sort | uniq -d)

legacy=$([[ -f "$legacy_file" ]] && grep -E '^SEC-T[0-9]+-[0-9]+$' "$legacy_file" || true)
while read -r section id; do
  [[ -z "$id" ]] && continue
  threat="${id#SEC-T}"; threat="${threat%%-*}"
  if [[ "$threat" != "$section" ]]; then
    report "threats: $id is defined in T$section.md, not T$threat.md"
  fi
  if [[ "$id" =~ ^SEC-T[0-9]+-[0-9]{1,2}$ ]]; then
    grep -qxF "$id" <<<"$legacy" ||
      report "threats: $id is a new two-digit ID; use SEC-T$threat-<issue>-<k> (security-review.md §2.1)"
  elif ! [[ "$id" =~ ^SEC-T[0-9]+-[0-9]{3,}-[0-9]+$ ]]; then
    report "threats: $id is not SEC-T<n>-<issue>-<k> (security-review.md §2.1)"
  fi
done <<<"$definitions"

defined=$(awk '{ print $2 }' <<<"$definitions" | sort -u)

# Every mention, with `/`-grouped numbers expanded (SEC-T4-01/02/03) and test names (testSECT4_01, testSECT<n>_<issue>_<k>)
# mapped.
mentions() {
  {
    grep -rhoE --exclude=check-sec-ids.test.sh --exclude=sec-ids-legacy.txt 'SEC-T[0-9]+-[0-9]+(-[0-9]+|(/[0-9]+)*)' "$@" 2>/dev/null || true
    grep -rhoE --exclude=check-sec-ids.test.sh 'testSECT[0-9]+_[0-9]+(_[0-9]+)?' "$@" 2>/dev/null |
      sed -E 's/^testSECT([0-9]+)_([0-9]+)_([0-9]+)$/SEC-T\1-\2-\3/; s/^testSECT([0-9]+)_([0-9]+)$/SEC-T\1-\2/' || true
  } | awk -F/ '{
      split($1, part, "-"); prefix = part[1] "-" part[2]
      print $1
      for (i = 2; i <= NF; i++) print prefix "-" $i
    }' | sort -u
}

sources=("$review" "$threats")
for dir in OvergroveTests scripts .github; do
  [[ -d "$root/$dir" ]] && sources+=("$root/$dir")
done
while read -r id; do
  [[ -z "$id" ]] && continue
  if ! grep -qxF "$id" <<<"$defined"; then
    number="${id#SEC-T}"
    test_name="testSECT${number%%-*}_${number#*-}"; test_name="${test_name//-/_}"
    where=$({ grep -rlE --exclude=check-sec-ids.test.sh --exclude=sec-ids-legacy.txt "${id}([^0-9-]|$)|${test_name}" "${sources[@]}" 2>/dev/null || true; } |
      sed "s|^$root/||" | head -3 | tr '\n' ' ')
    report "$id is mentioned (${where% }) but not defined on a 검증 list in docs/design/threats/"
  fi
done < <(mentions "${sources[@]}" | sed -E 's/^(SEC-T[0-9]+-)([0-9])$/\10\2/')

# PAR rows: `| PAR-WT-09 | …` as the first cell.
if [[ -f "$parsing" ]]; then
  while read -r id; do
    [[ -n "$id" ]] && report "parsing-spec.md: $id has more than one table row"
  done < <(grep -oE '^\| PAR-[A-Z0-9]+-[0-9]+ \|' "$parsing" | tr -d '| ' | sort | uniq -d)
fi

# Experiment rows: `| E43 | …` in security-review.md §4.
while read -r id; do
  [[ -n "$id" ]] && report "security-review.md: experiment $id has more than one row"
done < <(grep -oE '^\| E[0-9]+ \|' "$review" | tr -d '| ' | sort | uniq -d)

# PERF IDs (#288): defined once, as the first cell of a row in benchmark-plan.md §3's table (§3.1 lists tests and
# repeats IDs on purpose); every PERF ID or `test_PERF_nn` name used elsewhere is defined.
plan="$root/docs/performance/benchmark-plan.md"
perf_count=0
if [[ -f "$plan" ]]; then
  perf_defined=$(awk '
    /^## 3\./ { inside = 1; next }
    /^##/ { inside = 0 }
    inside && match($0, /^\| PERF-[0-9]+ \|/) { print substr($0, 3, RLENGTH - 4) }' "$plan")
  while read -r id; do
    [[ -n "$id" ]] && report "benchmark-plan.md: $id has more than one row in §3; give the newer measurement the next free number"
  done < <(sort <<<"$perf_defined" | uniq -d)
  perf_count=$(sort -u <<<"$perf_defined" | grep -c . || true)
  perf_sources=("$root/docs")
  for dir in OvergroveTests scripts .github; do
    [[ -d "$root/$dir" ]] && perf_sources+=("$root/$dir")
  done
  while read -r id; do
    [[ -z "$id" ]] && continue
    if ! grep -qxF "$id" <<<"$perf_defined"; then
      where=$({ grep -rlE --exclude=check-sec-ids.test.sh "${id}([^0-9]|$)|test_PERF_${id#PERF-}_" "${perf_sources[@]}" 2>/dev/null || true; } |
        sed "s|^$root/||" | head -3 | tr '\n' ' ')
      report "$id is mentioned (${where% }) but not defined in benchmark-plan.md §3"
    fi
  done < <({
    grep -rhoE --exclude=check-sec-ids.test.sh 'PERF-[0-9]+' "${perf_sources[@]}" 2>/dev/null || true
    grep -rhoE --exclude=check-sec-ids.test.sh 'test_PERF_[0-9]+' "${perf_sources[@]}" 2>/dev/null | sed 's/^test_PERF_/PERF-/' || true
  } | sort -u)
fi

if [[ "$status" -eq 0 ]]; then
  echo "ok  test IDs: $(wc -l <<<"$defined" | tr -d ' ') SEC definitions unique and in place, every SEC mention defined, PAR and E rows unique, $perf_count PERF IDs unique and defined"
fi
exit "$status"
