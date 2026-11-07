#!/usr/bin/env bash
# Tests scripts/lint/check-sec-ids.sh against small document trees (#282). No network.
# Run: scripts/lint/check-sec-ids.test.sh
set -euo pipefail
CHECK="$(cd "$(dirname "$0")" && pwd)/check-sec-ids.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

base_review='# 보안 검토

### T4. 필터

- **검증**: SEC-T4-01 (필터 → canary 없음), SEC-T4-02 (info attributes)

### T5. 전송

- **검증**: SEC-T5-01 (sshCommand)

## 4. 실험 기록

| ID | 실험 | 결과 |
|---|---|---|
| E01 | a | b |
| E02 | c | d |

| 항목 | 판단 | 확정 |
|---|---|---|
| 서브모듈 필터 | 확인됨 | SEC-T4-01 (대조군 포함) |
'

base_parsing='| ID | 입력 | 기대 |
|---|---|---|
| PAR-WT-01 | a | b |
| PAR-WT-02 | c | d |
'

# case_ <name> <expected exit 0|1, or a message the failure must contain> <review text> [parsing text] [test file]
case_() {
  local tree="$work/$1" expected="$2" message=""
  if [[ "$expected" != 0 ]]; then message="$expected"; expected=1; fi
  mkdir -p "$tree/docs/design" "$tree/docs/architecture" "$tree/OvergroveTests"
  printf '%s' "$3" >"$tree/docs/design/security-review.md"
  printf '%s' "${4:-$base_parsing}" >"$tree/docs/architecture/parsing-spec.md"
  printf '%s\n' "${5:-// SEC-T4-01/02: canary}" >"$tree/OvergroveTests/SampleTests.swift"
  local got=0 output
  output=$("$CHECK" "$tree" 2>&1) || got=$?
  if [[ "$got" == "$expected" && ( -z "$message" || "$output" == *"$message"* ) ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected exit $expected${message:+ with \"$message\"}, got $got: $output"
    fail=1
  fi
}

case_ baseline 0 "$base_review"
case_ reference-outside-verification-is-allowed 0 "$base_review"
case_ duplicate-definition "SEC-T5-01 is defined more than once" "${base_review/SEC-T5-01 (sshCommand)/SEC-T5-01 (sshCommand), SEC-T5-01 (gitProxy)}"
case_ duplicate-across-merged-prs "SEC-T4-02 is defined more than once" "${base_review/SEC-T4-02 (info attributes)/SEC-T4-02 (info attributes), SEC-T4-02 (submodule)}"
case_ wrong-section "SEC-T4-09 is defined under T5" "${base_review/SEC-T5-01 (sshCommand)/SEC-T5-01 (sshCommand), SEC-T4-09 (misplaced)}"
case_ undefined-in-test "SEC-T5-02 is mentioned" "$base_review" "$base_parsing" 'func testSECT5_02_Missing() {}'
case_ undefined-grouped-in-test "SEC-T4-03 is mentioned" "$base_review" "$base_parsing" '// SEC-T4-01/03'
case_ undefined-in-doc-body "SEC-T4-07 is mentioned" "${base_review/서브모듈 필터 | 확인됨 | SEC-T4-01/서브모듈 필터 | 확인됨 | SEC-T4-07}"
case_ test-name-defined 0 "$base_review" "$base_parsing" 'func testSECT4_02_InfoAttributes() {}'
case_ duplicate-par-row "PAR-WT-02 has more than one table row" "$base_review" "$base_parsing| PAR-WT-02 | e | f |
"
case_ duplicate-experiment-row "experiment E01 has more than one row" "${base_review/| E02 | c | d |/| E02 | c | d |
| E01 | again | x |}"

if [[ "$fail" -ne 0 ]]; then
  echo "check-sec-ids tests failed" >&2
  exit 1
fi
echo "check-sec-ids: all passed"
