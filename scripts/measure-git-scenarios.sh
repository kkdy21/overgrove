#!/usr/bin/env bash
# measure-git-scenarios.sh — measure-git-baseline.sh 에 없는 git 계층 시나리오를 잰다
#
# 사용법
#   scripts/measure-git-scenarios.sh [-n N] [--git PATH] BENCH_DIR BENCH_100K_DIR
#
#   BENCH_DIR       scripts/make-bench-repo.sh 기본값 출력 (repo/, worktrees/wt-00, wt-01 필요)
#   BENCH_100K_DIR  scripts/make-bench-repo.sh --files 100000 출력 (repo/ 필요)
#   -n N            시나리오별 반복 횟수 (기본 15)
#   --git PATH      git 실행 파일 (기본 /usr/bin/git. 앱과 같은 조건은 "$(xcode-select -p)/usr/bin/git")
#
# 시나리오 (결과: docs/performance/results/2026-11-06-apple-git-2.54.md)
#   S1  status, 추적 파일 1만 개
#   S2  status, 추적 파일 10만 개
#   S3  파일 mtime만 바뀌고 index가 갱신되지 않은 상태의 status (앱은 index를 쓰지 않는다), index 갱신 뒤와 비교
#   S4  무시되지 않은 untracked 파일 2만 개: --untracked-files=all 대 normal, 출력 크기
#   S5  로컬 브랜치 ahead/behind: for-each-ref %(upstream:track) 한 번 대 브랜치마다 rev-list
#   S6  RepoConfigInspector 의 config --list
#
# 주의: 기준 저장소를 바꾼다 (S3 은 파일 mtime 을 바꾸고 index 를 갱신하며, S4 는 untracked 디렉터리를 만들었다 지운다).
#       다른 측정을 이어서 하려면 기준 저장소를 다시 만든다.
# 의존성: bash 3.2+, git 2.36+, awk, sort, find (macOS 기본). 그 외 외부 도구 없음.

set -euo pipefail

N=15
GIT=/usr/bin/git
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -n) N="$2"; shift ;;
    --git) GIT="$2"; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
[ "${#ARGS[@]}" -eq 2 ] || { echo "usage: $0 [-n N] [--git PATH] BENCH_DIR BENCH_100K_DIR" >&2; exit 2; }
B="$(cd "${ARGS[0]}" && pwd -P)"; B100="$(cd "${ARGS[1]}" && pwd -P)"
R="$B/repo"; W0="$B/worktrees/wt-00"; W1="$B/worktrees/wt-01"; R100="$B100/repo"
for d in "$R" "$W0" "$W1" "$R100"; do [ -d "$d" ] || { echo "missing: $d" >&2; exit 2; }; done

# 앱과 같은 실행 조건 (git-command-catalog.md §2 공통 인자, 환경 변수 allowlist)
g() {
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" LC_ALL=C LANG=C \
    GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat PAGER=cat GIT_ASKPASS= SSH_ASKPASS= GIT_PROXY_COMMAND= \
    "$GIT" --no-pager --no-optional-locks --literal-pathspecs \
    -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.askPass= \
    -c protocol.ext.allow=never -c protocol.fd.allow=never \
    -c log.showSignature=false -c gc.auto=0 -c maintenance.auto=false -c color.ui=never "$@"
}
STATUS=(status --porcelain=v2 -z --branch --show-stash --untracked-files=all --ignore-submodules=dirty)
STATUS_NORMAL=(status --porcelain=v2 -z --branch --show-stash --untracked-files=normal --ignore-submodules=dirty)

measure() { # ID label cmd...
  local id="$1" label="$2"; shift 2
  "$@" >/dev/null 2>&1 || true   # 워밍업
  local i t times=""
  for i in $(awk -v n="$N" 'BEGIN { for (i = 1; i <= n; i++) print i }'); do
    t="$( { TIMEFORMAT=%3R; time "$@" >/dev/null 2>&1; } 2>&1 )"; times="$times $t"
  done
  printf '%s\n' $times | sort -n | awk -v id="$id" -v l="$label" -v n="$N" '
    { v[NR] = $1 * 1000 } END { printf "| %s | %s | %d | %.0f | %.0f |\n", id, l, n, v[int((NR*50+99)/100)], v[int((NR*95+99)/100)] }'
}

echo "## git scenarios"
echo
echo "- git: $("$GIT" --version) ($GIT)"
echo "- macOS: $(sw_vers -productVersion 2>/dev/null || uname -r), CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), cores: $(sysctl -n hw.ncpu 2>/dev/null || echo '?')"
echo "- iterations: $N (p50/p95 nearest-rank, ms, process spawn included)"
echo
echo "| ID | 시나리오 | N | p50 ms | p95 ms |"
echo "|---|---|---|---|---|"

measure S1 "status, 추적 파일 1만 개" g -C "$R" "${STATUS[@]}"
measure S2 "status, 추적 파일 10만 개" g -C "$R100" "${STATUS[@]}"

find "$W0/src" -type f -exec touch {} +
measure S3a "status, 파일 1만 개 mtime만 변경 (index 갱신 없음)" g -C "$W0" "${STATUS[@]}"
"$GIT" -C "$W0" update-index -q --refresh >/dev/null 2>&1 || true
measure S3b "같은 워크트리, index 갱신 뒤" g -C "$W0" "${STATUS[@]}"
find "$R100/src" -type f -exec touch {} +
measure S3c "status, 파일 10만 개 mtime만 변경 (index 갱신 없음)" g -C "$R100" "${STATUS[@]}"
"$GIT" -C "$R100" update-index -q --refresh >/dev/null 2>&1 || true
measure S3d "같은 저장소, index 갱신 뒤" g -C "$R100" "${STATUS[@]}"

mkdir -p "$W1/gen"
for d in $(awk 'BEGIN { for (i = 0; i < 40; i++) printf "%02d\n", i }'); do
  mkdir -p "$W1/gen/d$d"
  ( cd "$W1/gen/d$d" && awk 'BEGIN { for (i = 0; i < 500; i++) printf "f%03d.txt\n", i }' | xargs touch )
done
measure S4a "status --untracked-files=all, untracked 2만 개" g -C "$W1" "${STATUS[@]}"
measure S4b "status --untracked-files=normal, 같은 워크트리" g -C "$W1" "${STATUS_NORMAL[@]}"
printf '| S4c | 출력 크기 all / normal (bytes) | — | %s | %s |\n' \
  "$(g -C "$W1" "${STATUS[@]}" | wc -c | tr -d ' ')" "$(g -C "$W1" "${STATUS_NORMAL[@]}" | wc -c | tr -d ' ')"
rm -rf "$W1/gen"

FMT='--format=%(refname)%00%(objectname)%00%(*objectname)%00%(upstream)%00%(HEAD)%00%(committerdate:unix)%00%(symref)'
measure S5a "for-each-ref (현재 .refs 포맷)" g -C "$R" for-each-ref "$FMT" refs/heads refs/remotes refs/tags
measure S5b "for-each-ref + %(upstream:track,nobracket)" g -C "$R" for-each-ref "$FMT%00%(upstream:track,nobracket)" refs/heads refs/remotes refs/tags
per_branch() {
  local ref up
  g -C "$R" for-each-ref '--format=%(refname) %(upstream)' refs/heads | while read -r ref up; do
    if [ -n "$up" ]; then g -C "$R" rev-list --left-right --count --end-of-options "$up...$ref" >/dev/null; fi
  done
  return 0
}
measure S5c "rev-list --left-right --count × upstream 있는 로컬 브랜치" per_branch
measure S6 "config --list --show-scope -z --includes" g -C "$R" config --list --show-scope -z --includes
