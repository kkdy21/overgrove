#!/usr/bin/env bash
# Tests scripts/lint/check-sec-ids.sh against small document trees (#282). No network.
# Run: scripts/lint/check-sec-ids.test.sh
set -euo pipefail
CHECK="$(cd "$(dirname "$0")" && pwd)/check-sec-ids.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

base_review='# 보안 검토

## 2. 위협별 분석

| 위협 | 내용 |
|---|---|
| [T4](threats/T4.md) | 필터 |

## 4. 실험 기록

| ID | 실험 | 결과 |
|---|---|---|
| E01 | a | b |
| E02 | c | d |

| 항목 | 판단 | 확정 |
|---|---|---|
| 서브모듈 필터 | 확인됨 | SEC-T4-01 (대조군 포함) |
'

base_t4='# T4. 필터

- **대응**: 무력화
- **검증**:
  - SEC-T4-01 (필터 → canary 없음)
  - SEC-T4-02 (info attributes)
- **상태**: 적용됨
'

base_t5='# T5. 전송

- **검증**:
  - SEC-T5-01 (sshCommand)
'

base_legacy='SEC-T4-01
SEC-T4-02
SEC-T5-01
SEC-T4-09
'

base_parsing='| ID | 입력 | 기대 |
|---|---|---|
| PAR-WT-01 | a | b |
| PAR-WT-02 | c | d |
'

# case_ <name> <expected exit 0|1, or a message the failure must contain> [T5 text] [test file] [review text] [T4 text]
#   [parsing text]
case_() {
  local tree="$work/$1" expected="$2" message=""
  if [[ "$expected" != 0 ]]; then message="$expected"; expected=1; fi
  mkdir -p "$tree/docs/design/threats" "$tree/docs/architecture" "$tree/OvergroveTests" "$tree/scripts/lint"
  printf '%s' "${5:-$base_review}" >"$tree/docs/design/security-review.md"
  printf '%s' "${6:-$base_t4}" >"$tree/docs/design/threats/T4.md"
  printf '%s' "${3:-$base_t5}" >"$tree/docs/design/threats/T5.md"
  printf '%s' "${7:-$base_parsing}" >"$tree/docs/architecture/parsing-spec.md"
  printf '%s' "$base_legacy" >"$tree/scripts/lint/sec-ids-legacy.txt"
  printf '%s\n' "${4:-// SEC-T4-01/02: canary}" >"$tree/OvergroveTests/SampleTests.swift"
  local got=0 output
  output=$("$CHECK" "$tree" 2>&1) || got=$?
  if [[ "$got" == "$expected" && ( -z "$message" || "$output" == *"$message"* ) ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected exit $expected${message:+ with \"$message\"}, got $got: $output"
    fail=1
  fi
}

case_ baseline 0
case_ reference-outside-verification-is-allowed 0
case_ duplicate-definition "SEC-T5-01 is defined more than once" "${base_t5}  - SEC-T5-01 (gitProxy)
"
case_ duplicate-across-files "SEC-T4-02 is defined more than once" "${base_t5}  - SEC-T4-02 (also here)
"
case_ wrong-file "SEC-T4-09 is defined in T5.md, not T4.md" "${base_t5}  - SEC-T4-09 (misplaced)
"
case_ undefined-in-test "SEC-T5-02 is mentioned" "" 'func testSECT5_02_Missing() {}'
case_ undefined-grouped-in-test "SEC-T4-03 is mentioned" "" '// SEC-T4-01/03'
case_ undefined-in-doc-body "SEC-T4-07 is mentioned" "" "" "${base_review/서브모듈 필터 | 확인됨 | SEC-T4-01/서브모듈 필터 | 확인됨 | SEC-T4-07}"
case_ test-name-defined 0 "" 'func testSECT4_02_InfoAttributes() {}'
# #457: new IDs carry the issue number, so parallel PRs cannot collide; new two-digit IDs are refused.
case_ new-two-digit-id-refused "SEC-T5-02 is a new two-digit ID" "${base_t5}  - SEC-T5-02 (new)
"
case_ issue-id-accepted 0 "${base_t5}  - SEC-T5-457-1 (new)
  - SEC-T5-458-1 (other PR)
" 'func testSECT5_457_1_New() {}'
case_ issue-id-without-running-number "SEC-T5-457 is not SEC-T<n>-<issue>-<k>" "${base_t5}  - SEC-T5-457 (new)
"
case_ undefined-issue-id-in-test "SEC-T5-457-2 is mentioned" "" 'func testSECT5_457_2_Missing() {}'
case_ item-after-the-list-is-not-a-definition "SEC-T5-99 is mentioned" "${base_t5}- **상태**: 적용됨
  - SEC-T5-99 (outside the 검증 list)
"
case_ duplicate-par-row "PAR-WT-02 has more than one table row" "" "" "" "" "$base_parsing| PAR-WT-02 | e | f |
"
case_ duplicate-experiment-row "experiment E01 has more than one row" "" "" "${base_review/| E02 | c | d |/| E02 | c | d |
| E01 | again | x |}"

base_plan='# 벤치마크 계획

## 3. 측정 항목 (PERF)

| ID | 측정 | 연결 예산 |
|---|---|---|
| PERF-01 | 열기 | PB-1 |
| PERF-02 | 전환 | PB-2 |

### 3.1 지금 있는 XCTest

| ID | 테스트 | 판정 |
|---|---|---|
| PERF-01 | `test_PERF_01_open` | a |
| PERF-02 | `test_PERF_02_switch` | b |

## 4. 기준선
'

# perf_case_ <name> <0 or expected message> <plan text> [test file text]
perf_case_() {
  local tree="$work/perf-$1" expected="$2" message=""
  if [[ "$expected" != 0 ]]; then message="$expected"; expected=1; fi
  mkdir -p "$tree/docs/design/threats" "$tree/docs/performance" "$tree/OvergroveTests" "$tree/scripts/lint"
  printf '%s' "$base_review" >"$tree/docs/design/security-review.md"
  printf '%s' "$base_t4" >"$tree/docs/design/threats/T4.md"
  printf '%s' "$base_t5" >"$tree/docs/design/threats/T5.md"
  printf '%s' "$base_legacy" >"$tree/scripts/lint/sec-ids-legacy.txt"
  printf '%s' "$3" >"$tree/docs/performance/benchmark-plan.md"
  printf '%s\n' "${4:-func test_PERF_01_open() {}}" >"$tree/OvergroveTests/PerfTests.swift"
  local got=0 output
  output=$("$CHECK" "$tree" 2>&1) || got=$?
  if [[ "$got" == "$expected" && ( -z "$message" || "$output" == *"$message"* ) ]]; then
    echo "ok   perf-$1"
  else
    echo "FAIL perf-$1: expected exit $expected${message:+ with \"$message\"}, got $got: $output"
    fail=1
  fi
}

perf_case_ baseline-with-3.1-repeats 0 "$base_plan"
perf_case_ duplicate-row "PERF-02 has more than one row" "${base_plan/| PERF-02 | 전환 | PB-2 |/| PERF-02 | 전환 | PB-2 |
| PERF-02 | 메모리 | PB-6 |}"
perf_case_ undefined-test-name "PERF-07 is mentioned" "$base_plan" 'func test_PERF_07_memory() {}'
perf_case_ undefined-in-doc "PERF-09 is mentioned" "${base_plan/\#\# 4. 기준선/## 4. 기준선

PERF-09 결과는 여기에.}"

if [[ "$fail" -ne 0 ]]; then
  echo "check-sec-ids tests failed" >&2
  exit 1
fi
echo "check-sec-ids: all passed"
