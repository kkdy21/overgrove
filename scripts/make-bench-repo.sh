#!/usr/bin/env bash
# make-bench-repo.sh — Overgrove 성능 측정용 대형 Git 저장소 생성기 (결정적)
#
# 사용법
#   scripts/make-bench-repo.sh [옵션] [OUT_DIR]
#
#   --commits N       총 커밋 수 (기본 100000, merge 커밋 포함)
#   --files N         메인 워크트리 추적 파일 수 (기본 10000)
#   --worktrees N     워크트리 수, 메인 포함 (기본 10)
#   --lanes N         동시에 살아 있는 브랜치 레인 수 (기본 12, 그래프 레인 부하)
#   --commit-graph    생성 후 commit-graph 파일을 쓴다 (gc 를 거친 실제 저장소와 비슷한 조건)
#   --force           OUT_DIR 이 비어 있지 않아도 지우고 다시 만든다
#   OUT_DIR           생략하면 mktemp -d
#
# 출력 구조 (상세: docs/performance/benchmark-plan.md)
#   OUT_DIR/
#   ├── origin.git          bare 원격 (로컬 clone, hardlink)
#   ├── repo/               메인 워크트리 (main)
#   └── worktrees/wt-NN     링크드 워크트리 (lane/NN), 각각 WIP 변경 포함
#
# 생성 방식
#   커밋은 awk 가 만든 스트림을 git fast-import 로 한 번에 넣는다. 의사 난수는 Park–Miller LCG(seed 42)라
#   같은 옵션이면 항상 같은 이력이 나온다. lane/00, lane/01 은 merge 되지 않는 장수 브랜치이고,
#   나머지 레인은 일정 길이가 되면 main 에 merge 된 뒤 main 끝에서 다시 시작한다.
#   merge 커밋의 트리는 main 쪽을 따른다 (그래프 부하가 목적이며 내용 병합은 흉내 내지 않는다).
#
# 의존성: bash 3.2+, git 2.36+, awk (macOS 기본). 그 외 외부 도구 없음.

set -euo pipefail

COMMITS=100000
FILES=10000
WORKTREES=10
LANES=12
COMMIT_GRAPH=0
FORCE=0
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --commits) COMMITS="$2"; shift ;;
    --files) FILES="$2"; shift ;;
    --worktrees) WORKTREES="$2"; shift ;;
    --lanes) LANES="$2"; shift ;;
    --commit-graph) COMMIT_GRAPH=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) OUT="$1" ;;
  esac
  shift
done

for v in COMMITS FILES WORKTREES LANES; do
  eval "val=\$$v"
  case "$val" in ''|*[!0-9]*) echo "error: --$(echo "$v" | tr 'A-Z' 'a-z') must be a positive integer" >&2; exit 2 ;; esac
done
if [ "$WORKTREES" -lt 1 ] || [ "$WORKTREES" -gt $((LANES + 1)) ]; then
  echo "error: --worktrees must be between 1 and lanes+1 ($((LANES + 1)))" >&2
  exit 2
fi
if [ "$LANES" -lt 3 ]; then
  echo "error: --lanes must be at least 3" >&2
  exit 2
fi

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/overgrove-bench.XXXXXX")"
else
  if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
    [ "$FORCE" -eq 1 ] || { echo "error: $OUT is not empty (use --force)" >&2; exit 1; }
    rm -rf "$OUT"
  fi
  mkdir -p "$OUT"
fi
OUT="$(cd "$OUT" && pwd -P)"
R="$OUT/repo"
WT="$OUT/worktrees"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT 2>/dev/null || true
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0
export GIT_ADVICE=0
export GIT_AUTHOR_NAME="Bench Author" GIT_AUTHOR_EMAIL="bench@example.invalid"
export GIT_COMMITTER_NAME="Bench Committer" GIT_COMMITTER_EMAIL="bench@example.invalid"
END_TS=$((1700000000 + (COMMITS + 10) * 60))

now() { date +%s; }
# range A B: A..B 를 한 줄씩 출력. A > B 면 아무것도 출력하지 않는다 (BSD seq 는 거꾸로 센다).
range() { local i="$1"; while [ "$i" -le "$2" ]; do echo "$i"; i=$((i + 1)); done; }
T0=$(now)

git init -q -b main "$R"
cd "$R"
git config commit.gpgSign false
git config gc.auto 0          # 생성 중 auto gc 방지 (측정 조건을 흔들지 않도록)
git config maintenance.auto false

# ---------------------------------------------------------------------------
# 1. fast-import 스트림 생성과 적재
# ---------------------------------------------------------------------------
awk -v N="$COMMITS" -v F="$FILES" -v L="$LANES" '
function rnd(n) { seed = (seed * 16807) % 2147483647; return seed % n }
function fpath(f) { return sprintf("src/d%02d/f%05d.txt", f % 100, f) }
function header(ref, mk, ts, a, msg) {
  printf "commit %s\nmark :%d\n", ref, mk
  printf "author Dev %02d <dev%02d@example.invalid> %d +0000\n", a, a, ts
  printf "committer Dev %02d <dev%02d@example.invalid> %d +0000\n", a, a, ts
  printf "data %d\n%s\n", length(msg), msg
}
function modify(i,   f, c) {
  f = rnd(F)
  c = "file " f " v" i
  printf "M 100644 inline %s\ndata %d\n%s\n\n", fpath(f), length(c) + 1, c
}
BEGIN {
  seed = 42; base = 1700000000
  split("feat fix docs refactor test perf chore", types, " ")
  header("refs/heads/main", 1, base, 0, "chore: initial import")
  for (f = 0; f < F; f++) {
    c = "file " f " v0"
    printf "M 100644 inline %s\ndata %d\n%s\n", fpath(f), length(c) + 1, c
  }
  printf "\n"
  maintip = 1
  for (l = 0; l < L; l++) { ltip[l] = 0; lcount[l] = 0; llen[l] = 5 + rnd(40) }
  for (i = 2; i <= N; i++) {
    ts = base + i * 60
    a = rnd(20)
    t = rnd(L + 2)
    msg = sprintf("%s(area-%02d): change %d", types[1 + rnd(7)], rnd(30), i)
    if (t >= L) {
      header("refs/heads/main", i, ts, a, msg); modify(i); maintip = i
    } else if (ltip[t] == 0) {
      header(sprintf("refs/heads/lane/%02d", t), i, ts, a, msg)
      printf "from :%d\n", maintip
      modify(i); ltip[t] = i; lcount[t] = 1
    } else if (t >= 2 && lcount[t] >= llen[t]) {
      header("refs/heads/main", i, ts, a, sprintf("Merge branch %clane/%02d%c", 39, t, 39))
      printf "merge :%d\n\n", ltip[t]
      maintip = i; ltip[t] = 0; lcount[t] = 0; llen[t] = 5 + rnd(40)
    } else {
      header(sprintf("refs/heads/lane/%02d", t), i, ts, a, msg); modify(i); ltip[t] = i; lcount[t]++
    }
    if (i % 10000 == 0) printf "reset refs/tags/bench-%d\nfrom :%d\n\n", i, maintip
  }
  # 아직 한 번도 커밋되지 않은 레인이 있으면 main 끝에서 1개씩 만든다 (워크트리용 브랜치 보장)
  for (l = 0; l < L; l++) if (ltip[l] == 0) {
    N++; header(sprintf("refs/heads/lane/%02d", l), N, base + N * 60, 0, sprintf("chore: start lane/%02d", l))
    printf "from :%d\n", maintip; modify(N)
  }
}' | git fast-import --quiet

git reset -q --hard main
T_IMPORT=$(now)

# ---------------------------------------------------------------------------
# 2. 원격, upstream, ahead/behind
# ---------------------------------------------------------------------------
git clone -q --bare "$R" "$OUT/origin.git"
git remote add origin "$OUT/origin.git"
git fetch -q origin

ahead_behind() {   # <branch> <ahead> <behind>
  local b="$1" ahead="$2" behind="$3" k c tip
  git config "branch.$b.remote" origin
  git config "branch.$b.merge" "refs/heads/$b"
  tip="$(git rev-parse "refs/remotes/origin/$b")"
  for k in $(range 1 "$behind"); do
    c="$(GIT_AUTHOR_DATE="@$END_TS +0000" GIT_COMMITTER_DATE="@$END_TS +0000" \
         git commit-tree "$tip^{tree}" -p "$tip" -m "chore: remote-only $k on $b")"
    tip="$c"
  done
  git update-ref "refs/remotes/origin/$b" "$tip"
  tip="$(git rev-parse "refs/heads/$b")"
  for k in $(range 1 "$ahead"); do
    c="$(GIT_AUTHOR_DATE="@$END_TS +0000" GIT_COMMITTER_DATE="@$END_TS +0000" \
         git commit-tree "$tip^{tree}" -p "$tip" -m "chore: local-only $k on $b")"
    tip="$c"
  done
  git update-ref "refs/heads/$b" "$tip"
}

ahead_behind main 1 2
for n in $(range 0 $((WORKTREES - 2))); do
  b="$(printf 'lane/%02d' "$n")"
  ahead_behind "$b" $((n % 3)) $(((n + 1) % 3))
done
git reset -q --hard main   # main 의 로컬 커밋은 트리가 같으므로 워크트리 내용은 그대로다

# ---------------------------------------------------------------------------
# 3. 링크드 워크트리와 WIP
# ---------------------------------------------------------------------------
mkdir -p "$WT"
for n in $(range 0 $((WORKTREES - 2))); do
  b="$(printf 'lane/%02d' "$n")"
  git worktree add -q "$WT/$(printf 'wt-%02d' "$n")" "$b"
done

add_wip() {   # <worktree dir> <salt>
  local d="$1" s="$2" k f
  (
    cd "$d"
    for k in $(range 0 19); do
      f="$(printf 'src/d%02d/f%05d.txt' $(((k * 7 + s) % 100)) $(((k * 7 + s) % 100 + 100 * k)))"
      [ -f "$f" ] && printf 'wip %s\n' "$s" >> "$f"
      if [ "$k" -lt 5 ] && [ -f "$f" ]; then git add -- "$f"; fi
    done
    mkdir -p scratch
    for k in $(range 0 9); do printf 'untracked %s %s\n' "$s" "$k" > "scratch/new-$k.txt"; done
  )
}

add_wip "$R" 0
for n in $(range 0 $((WORKTREES - 2))); do
  add_wip "$WT/$(printf 'wt-%02d' "$n")" $((n + 1))
done

# stash 5개 (메인 워크트리)
for k in 1 2 3 4 5; do
  f="$(printf 'src/d%02d/f%05d.txt' $((50 + k)) $((50 + k)))"
  printf 'stash %s\n' "$k" >> "$f"
  GIT_AUTHOR_DATE="@$((END_TS + k)) +0000" GIT_COMMITTER_DATE="@$((END_TS + k)) +0000" \
    git stash push -q -m "bench stash $k" -- "$f"
done

if [ "$COMMIT_GRAPH" -eq 1 ]; then
  git commit-graph write --reachable --changed-paths >/dev/null 2>&1
fi
T_END=$(now)

# ---------------------------------------------------------------------------
# 4. 요약
# ---------------------------------------------------------------------------
echo "Overgrove bench repo created: $OUT"
echo "  commits (all refs): $(git rev-list --all --count)"
echo "  merges:             $(git rev-list --all --merges --count)"
echo "  branches:           $(git for-each-ref refs/heads | wc -l | tr -d ' ')"
echo "  tags:               $(git for-each-ref refs/tags | wc -l | tr -d ' ')"
echo "  tracked files:      $(git ls-files | wc -l | tr -d ' ')"
echo "  worktrees:          $(git worktree list | wc -l | tr -d ' ')"
echo "  stashes:            $(git stash list | wc -l | tr -d ' ')"
echo "  commit-graph:       $([ -f .git/objects/info/commit-graph ] || [ -d .git/objects/info/commit-graphs ] && echo yes || echo no)"
echo "  .git size:          $(du -sh .git | cut -f1)"
echo "  time: import $((T_IMPORT - T0))s, total $((T_END - T0))s"
