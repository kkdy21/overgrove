#!/usr/bin/env bash
# measure-git-baseline.sh — 앱 없이 git 계층의 비용을 잰다 (Overgrove 성능 예산의 하한선)
#
# 사용법
#   scripts/measure-git-baseline.sh [-n N] [--git PATH] [--only REGEX] BENCH_DIR
#
#   BENCH_DIR      scripts/make-bench-repo.sh 의 출력 디렉터리 (repo/, worktrees/ 를 포함)
#   -n N           항목별 반복 횟수 (기본 20). p95 는 nearest-rank 방식이므로 N>=20 을 권장한다
#   --git PATH     git 실행 파일 (기본 /usr/bin/git — 앱의 기본값과 같다)
#   --only REGEX   ID 가 REGEX 와 맞는 항목만 실행 (예: 'B0[2-4]')
#
# 측정 조건
#   - 앱과 같은 방식으로 실행한다: 부모 환경을 버리고(env -i) allowlist 환경 변수만 넘기며,
#     공통 보안 인자(-c core.fsmonitor=false -c core.hooksPath=/dev/null ...)를 붙인다.
#   - 시간은 bash 내장 time(TIMEFORMAT=%3R, ms 해상도)으로 잰다. 프로세스 생성 비용이 포함된다.
#   - 출력은 /dev/null 로 버린다. 파싱과 렌더링 비용은 포함되지 않는다 (그것은 앱 측 측정 PERF-xx 의 몫).
#   - 결과는 Markdown 표로 출력하므로 docs/performance/benchmark-plan.md 에 그대로 붙일 수 있다.
#
# 의존성: bash 3.2+, git 2.36+, awk, sort (macOS 기본). 그 외 외부 도구 없음.

set -euo pipefail

N=20
GIT=/usr/bin/git
ONLY=""
DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n) N="$2"; shift ;;
    --git) GIT="$2"; shift ;;
    --only) ONLY="$2"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) DIR="$1" ;;
  esac
  shift
done
[ -n "$DIR" ] && [ -d "$DIR/repo" ] || { echo "usage: $0 [-n N] BENCH_DIR (must contain repo/)" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd -P)"
R="$DIR/repo"

WTS=("$R")
for d in "$DIR"/worktrees/wt-*; do [ -d "$d" ] && WTS+=("$d"); done

# 앱과 같은 실행 조건 (docs/architecture/git-command-catalog.md §2.1 공통 인자, §2.4 환경 변수와 맞춘다)
# 차이: 측정 편의상 작업 디렉터리를 -C 로 넘긴다 (앱은 Process.currentDirectoryURL). 비용 차이는 무시할 수준이다.
g() {
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" LC_ALL=C LANG=C \
    GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat PAGER=cat \
    GIT_ASKPASS= SSH_ASKPASS= GIT_PROXY_COMMAND= \
    "$GIT" --no-pager --no-optional-locks --literal-pathspecs \
    -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.askPass= \
    -c protocol.ext.allow=never -c protocol.fd.allow=never \
    -c log.showSignature=false -c gc.auto=0 -c maintenance.auto=false -c color.ui=never \
    "$@"
}

LOGFMT='--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s'
STATUS=(status --porcelain=v2 -z --branch --untracked-files=all)
FILE="src/d01/f00001.txt"

status_seq() { local d; for d in "${WTS[@]}"; do g -C "$d" "${STATUS[@]}" >/dev/null; done; }
status_par() { local d; for d in "${WTS[@]}"; do g -C "$d" "${STATUS[@]}" >/dev/null & done; wait; }
ab_seq()     { local d; for d in "${WTS[@]}"; do g -C "$d" rev-list --left-right --count '@{u}...HEAD' >/dev/null 2>&1 || true; done; }

# measure <ID> <설명> <명령...>
RESULTS=""
measure() {
  local id="$1" label="$2"; shift 2
  if [ -n "$ONLY" ] && ! printf '%s' "$id" | grep -Eq "$ONLY"; then return 0; fi
  local i t times="" bytes
  bytes="$("$@" 2>/dev/null | wc -c | tr -d ' ')" || bytes="?"     # 워밍업 1회 + 출력 크기
  for i in $(awk -v n="$N" 'BEGIN { for (i = 1; i <= n; i++) print i }'); do
    t="$( { TIMEFORMAT=%3R; time "$@" >/dev/null 2>&1; } 2>&1 )"
    times="$times $t"
  done
  local stats
  stats="$(printf '%s\n' $times | sort -n | awk '
    { v[NR] = $1 * 1000 }
    END {
      p50 = v[int((NR * 50 + 99) / 100)]; p95 = v[int((NR * 95 + 99) / 100)]
      printf "%.0f | %.0f | %.0f", p50, p95, v[NR]
    }')"
  local row
  row="$(printf '| %s | %s | %s | %s | %s |' "$id" "$label" "$N" "$stats" "$bytes")"
  printf '%s\n' "$row"
  RESULTS="$RESULTS$row"$'\n'
}

echo "## git baseline"
echo
echo "- git: $("$GIT" --version)"
echo "- macOS: $(sw_vers -productVersion 2>/dev/null || uname -r), CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), cores: $(sysctl -n hw.ncpu 2>/dev/null || echo '?')"
echo "- repo: commits=$(g -C "$R" rev-list --all --count), tracked files=$(g -C "$R" ls-files | wc -l | tr -d ' '), worktrees=${#WTS[@]}, commit-graph=$([ -e "$R/.git/objects/info/commit-graph" ] || [ -d "$R/.git/objects/info/commit-graphs" ] && echo yes || echo no)"
echo "- iterations: $N (p50/p95 nearest-rank, ms, process spawn included)"
echo
echo "| ID | 항목 | N | p50 ms | p95 ms | max ms | 출력 bytes |"
echo "|---|---|---|---|---|---|---|"

measure B01 "worktree list --porcelain -z"                      g -C "$R" worktree list --porcelain -z
measure B02 "status v2 (메인 워크트리 1개)"                      g -C "$R" "${STATUS[@]}"
measure B03 "status v2 × ${#WTS[@]} 순차"                        status_seq
measure B04 "status v2 × ${#WTS[@]} 병렬"                        status_par
measure B05 "rev-list ahead/behind × ${#WTS[@]} 순차"            ab_seq
measure B06 "for-each-ref heads/remotes/tags"                    g -C "$R" for-each-ref '--format=%(refname)%00%(objectname)%00%(upstream)%00%(upstream:track)' refs/heads refs/remotes refs/tags
measure B07 "stash list"                                         g -C "$R" stash list -z '--format=%gd%x00%H%x00%gs%x00%ct'
measure B08 "log 첫 500개 --date-order (refs/stash 제외)"         g -C "$R" log --exclude=refs/stash --all --date-order -z "$LOGFMT" -n 500
measure B09 "log 첫 500개 기본 순서 (refs/stash 제외)"            g -C "$R" log --exclude=refs/stash --all -z "$LOGFMT" -n 500
measure B10 "log 전체 메타데이터 --date-order"                    g -C "$R" log --exclude=refs/stash --all --date-order -z "$LOGFMT"
measure B11 "show --numstat HEAD (커밋 상세)"                     g -C "$R" show --numstat --no-ext-diff --no-textconv -z "$LOGFMT" HEAD
measure B12 "log --follow 첫 100개 (파일 이력)"                   g -C "$R" log --follow -z "$LOGFMT" -n 100 -- "$FILE"
measure B13 "log -- path 첫 100개 (follow 없음)"                  g -C "$R" log -z "$LOGFMT" -n 100 -- "$FILE"
measure B14 "stash show --numstat stash@{0}"                      g -C "$R" stash show --numstat --no-ext-diff --no-textconv -z 'stash@{0}'
measure B15 "diff --numstat (워크트리 대 인덱스)"                  g -C "$R" diff --numstat --no-ext-diff --no-textconv -z
measure B16 "diff --cached --numstat"                             g -C "$R" diff --cached --numstat --no-ext-diff --no-textconv -z
measure B17 "rev-list --count --all"                              g -C "$R" rev-list --count --all
measure B18 "log 500개 페이지 --skip=50000 --date-order"           g -C "$R" log --exclude=refs/stash --all --date-order -z "$LOGFMT" --skip=50000 -n 500
