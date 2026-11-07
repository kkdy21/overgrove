#!/usr/bin/env bash
# make-fixture-repo.sh — Overgrove 통합·보안 테스트용 결정적 Git 픽스처 생성기
#
# 사용법
#   scripts/make-fixture-repo.sh [--malicious] [--force] [--quiet] [OUT_DIR]
#
#   OUT_DIR       생성 위치. 생략하면 mktemp -d 로 만든다. 비어 있지 않은 디렉터리는 --force 가 있어야 지운다.
#   --malicious   저장소 로컬 설정에 무해한 canary 페이로드(T1–T8)를 심는다.
#                 페이로드는 OUT_DIR/canary/ 에 파일을 남기는 것 외에는 아무것도 하지 않는다.
#                 보안 테스트는 "명령 실행 후 canary/ 가 비어 있다"를 검증한다.
#   --force       OUT_DIR 이 비어 있지 않아도 지우고 다시 만든다.
#   --quiet       마지막 요약을 출력하지 않는다. 마지막 줄에 OUT_DIR 만 출력한다.
#
# 출력 구조 (상세: docs/testing/fixtures.md)
#   OUT_DIR/
#   ├── remotes/origin.git, remotes/upstream.git   bare 원격 2개
#   ├── repo/                                      메인 워크트리 (main, ahead 1, WIP 상태 전부)
#   ├── worktrees/wt-*                             링크드 워크트리 (ahead/behind/diverged/no-upstream/conflict/locked/detached/prunable)
#   ├── canary/                                    --malicious 일 때만. 비어 있어야 정상
#   └── payloads/                                  --malicious 일 때만. canary 를 만드는 무해한 스크립트
#
# 결정성
#   작성자·커미터·날짜를 고정하고 사용자 전역 설정을 차단한다(GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM=1).
#   같은 git 버전이면 커밋 SHA 가 항상 같다. 경로가 들어가는 설정 값(원격 URL, 페이로드 경로)만 OUT_DIR 에 따라 달라진다.
#
# 의존성: bash 3.2+, git 2.36+ (worktree list -z). 그 외 외부 도구 없음.

set -euo pipefail

MALICIOUS=0
FORCE=0
QUIET=0
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --malicious) MALICIOUS=1 ;;
    --force) FORCE=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    --) shift; OUT="${1:-}"; break ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) OUT="$1" ;;
  esac
  shift
done

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/overgrove-fixture.XXXXXX")"
else
  if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
    if [ "$FORCE" -ne 1 ]; then
      echo "error: $OUT is not empty (use --force to recreate)" >&2
      exit 1
    fi
    rm -rf "$OUT"
  fi
  mkdir -p "$OUT"
fi
OUT="$(cd "$OUT" && pwd -P)"

case "$OUT" in
  *\'*|*$'\n'*) echo "error: OUT_DIR must not contain single quotes or newlines" >&2; exit 2 ;;
esac

REM="$OUT/remotes"
R="$OUT/repo"
WT="$OUT/worktrees"

# ---------------------------------------------------------------------------
# 격리된 git 환경 (생성 과정 전용)
# ---------------------------------------------------------------------------
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_SSH GIT_SSH_COMMAND GIT_ASKPASS SSH_ASKPASS \
      GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_EXTERNAL_DIFF GIT_PAGER GIT_EDITOR 2>/dev/null || true
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0
export GIT_ADVICE=0

BASE_TS=1700000000   # 2023-11-14T22:13:20Z
TICK=0
AUTHOR_NAMES=("Alice Example" "Bob Example" "김개발")
AUTHOR_MAILS=("alice@example.invalid" "bob@example.invalid" "kim@example.invalid")

# 다음 커밋·태그·stash 의 작성자와 날짜를 고정한다.
tick() {
  TICK=$((TICK + 1))
  local ts=$((BASE_TS + TICK * 3600))
  local i=$((TICK % 3))
  export GIT_AUTHOR_NAME="${AUTHOR_NAMES[$i]}"
  export GIT_AUTHOR_EMAIL="${AUTHOR_MAILS[$i]}"
  export GIT_AUTHOR_DATE="@$ts +0000"
  export GIT_COMMITTER_NAME="Fixture Committer"
  export GIT_COMMITTER_EMAIL="committer@example.invalid"
  export GIT_COMMITTER_DATE="@$ts +0000"
}

commit() {
  tick
  git commit -q --no-verify --no-gpg-sign "$@"
}

# 파일 끝에 한 줄을 붙이고 그 메시지로 커밋한다.
change() {
  local file="$1" msg="$2"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$msg" >> "$file"
  git add -- "$file"
  commit -m "$msg"
}

mkdir -p "$REM" "$WT"
git init -q --bare -b main "$REM/origin.git"
git init -q --bare -b main "$REM/upstream.git"
git init -q -b main "$R"
cd "$R"
git config commit.gpgSign false
git config tag.gpgSign false

# ---------------------------------------------------------------------------
# 1. 기본 이력
# ---------------------------------------------------------------------------
mkdir -p src docs assets scripts "dir with space"
printf '# Overgrove fixture\n' > README.md
for f in staged-modified staged-deleted old-name staged-and-unstaged unstaged-modified \
         unstaged-deleted stash-target filter-target; do
  printf '%s line 1\n%s line 2\n' "$f" "$f" > "src/$f.txt"
done
printf 'base\nshared line\nend\n' > conflict.txt
printf 'will be deleted by us\n' > deleted-by-us.txt
printf 'guide v1\nintro\nusage\n' > docs/guide.md
printf '\000\001\002binary-v1\000' > assets/binary.bin
printf '#!/bin/sh\necho run\n' > scripts/run.sh
ln -s ../README.md src/typechange
printf '*.log\n' > .gitignore
# 특수 파일명 (커밋되는 것)
printf 'space\n'   > "with space.txt"
printf 'newline\n' > $'line\nbreak.txt'
printf 'dash\n'    > ./-dash-leading.txt
printf 'dq\n'      > 'quote"double.txt'
printf 'sq\n'      > "it's.txt"
printf 'bs\n'      > 'back\slash.txt'
printf 'nfc\n'     > $'caf\xc3\xa9.txt'
printf 'emoji\n'   > $'emoji-\xf0\x9f\x8c\xb2.txt'
printf 'nested\n'  > "dir with space/file.txt"
git add -A
commit -m "chore: initial fixture content"

printf 'guide v1\nintro\nusage\ndetails\n' > docs/guide.md
printf '\000\001\002binary-v2\000\377' > assets/binary.bin
git add -A
commit -m "feat: add guide details and update binary"
git tag light-tag

git switch -q -c feat/merged
change merged/one.txt "feat: merged work 1"
change merged/two.txt "feat: merged work 2"
git switch -q main
change README.md "fix: tweak readme"
tick
git tag -a v0.0.1 -m "fixture release v0.0.1"
tick
git merge -q --no-ff --no-edit -m "Merge branch 'feat/merged'" feat/merged

git mv docs/guide.md docs/manual.md
printf 'manual v2\nintro\nusage\ndetails\n' > docs/manual.md
git add -A
commit -m "docs: rename guide to manual"
change docs/manual.md "docs: update manual"

# ---------------------------------------------------------------------------
# 2. 원격과 ahead/behind
# ---------------------------------------------------------------------------
git remote add origin "$REM/origin.git"
git remote add upstream "$REM/upstream.git"
git push -q -u origin main
git push -q upstream main

# upstream/main 에만 있는 커밋 1개
change README.md "chore: upstream-only change"
git push -q upstream main
git reset -q --hard HEAD~1
git fetch -q upstream
# upstream/HEAD symref. git 2.48 이상의 fetch만 자동으로 만들므로, 2.36 이상 어느 버전에서도 같은 ref가 되도록 직접 만든다 (#99)
git remote set-head upstream main >/dev/null

# 자격 증명이 섞인 원격 URL (마스킹 테스트용). 값은 런타임에 조합하며 실제 비밀이 아니다.
cred_user="fixture-user"
cred_pass="fixture-pass-$(printf '%s' not-a-secret)"
git remote add mirror "https://${cred_user}:${cred_pass}@example.invalid/overgrove-fixture.git"
git config remote.mirror.skipFetchAll true

git switch -q -c feat/ahead main
change branches/feat-ahead.txt "feat: ahead 1"
git push -q -u origin feat/ahead
change branches/feat-ahead.txt "feat: ahead 2"
change branches/feat-ahead.txt "feat: ahead 3"

git switch -q -c feat/behind main
change branches/feat-behind.txt "feat: behind 1"
change branches/feat-behind.txt "feat: behind 2"
change branches/feat-behind.txt "feat: behind 3"
git push -q -u origin feat/behind
git reset -q --hard HEAD~2

git switch -q -c feat/diverged main
change branches/feat-diverged.txt "feat: diverged remote"
git push -q -u origin feat/diverged
git reset -q --hard HEAD~1
change branches/feat-diverged.txt "feat: diverged local"

git switch -q -c feat/no-upstream main
change branches/feat-no-upstream.txt "feat: no upstream"

git switch -q -c topic/conflict-other main
printf 'base\nshared line (theirs)\nend\n' > conflict.txt
printf 'both added (theirs)\n' > both-added.txt
printf 'modified by them\n' >> deleted-by-us.txt
git add -A
commit -m "feat: conflicting change (theirs)"

git switch -q -c fix/conflict main
printf 'base\nshared line (ours)\nend\n' > conflict.txt
printf 'both added (ours)\n' > both-added.txt
git rm -q deleted-by-us.txt
git add -A
commit -m "fix: conflicting change (ours)"

git branch chore/locked main
git branch spike/prunable main

# origin 에만 있고 로컬은 아직 모르는 브랜치 (fetch 후에 나타나야 함, fetch 가 ref 를 실제로 갱신하게 만듦)
git switch -q -c tmp/remote-only main
change branches/feat-remote-only.txt "feat: remote-only work"
git push -q origin tmp/remote-only:refs/heads/feat/remote-only
git switch -q main
git branch -q -D tmp/remote-only
git update-ref -d refs/remotes/origin/feat/remote-only

git switch -q main
change branches/main.txt "feat: local-only change on main"

# ---------------------------------------------------------------------------
# 3. 링크드 워크트리
# ---------------------------------------------------------------------------
git worktree add -q "$WT/wt-ahead" feat/ahead
git worktree add -q "$WT/wt-behind" feat/behind
git worktree add -q "$WT/wt-diverged" feat/diverged
git worktree add -q "$WT/wt-no-upstream" feat/no-upstream
git worktree add -q "$WT/wt-conflict" fix/conflict
git worktree add -q "$WT/wt-locked" chore/locked
git worktree add -q "$WT/wt-prunable" spike/prunable
git worktree add -q --detach "$WT/wt-detached" main~2
git worktree lock --reason "fixture: locked on purpose" "$WT/wt-locked"
rm -rf "$WT/wt-prunable"

# ---------------------------------------------------------------------------
# 4. stash 2개 (stash@{1}: 추적 파일만, stash@{0}: -u 로 미추적 포함)
# ---------------------------------------------------------------------------
printf 'stashed change\n' >> src/stash-target.txt
tick
git stash push -q -m "fixture: tracked change"

(
  cd "$WT/wt-ahead"
  printf 'stashed on ahead\n' >> branches/feat-ahead.txt
  printf 'untracked in stash\n' > stash-untracked.txt
  tick
  git stash push -q -u -m "fixture: with untracked"
)

# ---------------------------------------------------------------------------
# 5. 충돌 상태 (wt-conflict: UU, AA, DU)
# ---------------------------------------------------------------------------
(
  cd "$WT/wt-conflict"
  tick
  git merge -q --no-edit topic/conflict-other >/dev/null 2>&1 || true
)

# wt-diverged 에 미추적 파일 1개
printf 'local notes\n' > "$WT/wt-diverged/notes.txt"

# ---------------------------------------------------------------------------
# 6. 메인 워크트리 WIP
# ---------------------------------------------------------------------------
printf 'staged change\n' >> src/staged-modified.txt
git add src/staged-modified.txt
printf 'new staged file\n' > src/staged-added.txt
git add src/staged-added.txt
git rm -q src/staged-deleted.txt
git mv src/old-name.txt src/new-name.txt
printf 'staged part\n' >> src/staged-and-unstaged.txt
git add src/staged-and-unstaged.txt
printf 'unstaged part\n' >> src/staged-and-unstaged.txt
printf 'unstaged change\n' >> src/unstaged-modified.txt
rm src/unstaged-deleted.txt
rm src/typechange
printf 'now a regular file\n' > src/typechange
chmod +x scripts/run.sh
printf 'intent to add\n' > intent.txt
git add -N intent.txt
printf 'staged newline-name change\n' >> $'line\nbreak.txt'
git add -- $'line\nbreak.txt'
printf 'unstaged space-name change\n' >> "with space.txt"
printf 'unstaged dash-name change\n' >> ./-dash-leading.txt
# 미추적
printf 'untracked\n' > untracked.txt
mkdir -p "untracked dir"
printf 'nested untracked\n' > "untracked dir/nested.txt"
printf 'tab\n' > $'tab\there.txt'
printf 'nfd\n' > $'e\xcc\x81te\xcc\x81.txt'
printf 'hangul\n' > $'\xed\x95\x9c\xea\xb8\x80 \xed\x8c\x8c\xec\x9d\xbc.txt'
printf 'option-like\n' > ./--option-like.txt
# 무시됨 (기본 status 에 나오지 않아야 함)
printf 'ignored\n' > debug.log

# ---------------------------------------------------------------------------
# 7. 요약 (안전한 인자로 수집)
# ---------------------------------------------------------------------------
safe_git() {
  env LC_ALL=C GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

count_status() {
  # porcelain v2 -z 레코드를 종류별로 센다. rename(2) 레코드 뒤의 원래 경로 필드는 건너뛴다.
  local dir="$1"
  safe_git -C "$dir" status --porcelain=v2 -z --untracked-files=all 2>/dev/null \
    | tr '\0' '\n' | awk '
      skip { skip = 0; next }
      /^1 / { x = substr($2, 1, 1); y = substr($2, 2, 1); if (x != ".") s++; if (y != ".") u++; next }
      /^2 / { x = substr($2, 1, 1); y = substr($2, 2, 1); if (x != ".") s++; if (y != ".") u++; skip = 1; next }
      /^u / { c++; next }
      /^\? / { n++; next }
      END { printf "staged=%d unstaged=%d untracked=%d conflicted=%d", s, u, n, c }'
}

SUMMARY="$(
  echo "== worktrees"
  safe_git worktree list
  echo
  echo "== status counts"
  for d in "$R" "$WT"/wt-*; do
    [ -d "$d" ] || continue
    printf '%-40s %s\n' "${d#"$OUT"/}" "$(count_status "$d")"
  done
  echo
  echo "== branches (upstream, track)"
  safe_git for-each-ref --format='%(refname:short) %(upstream:short) %(upstream:track)' refs/heads
  echo
  echo "== stashes"
  safe_git stash list --format='%gd %gs'
  echo
  echo "== remotes"
  safe_git remote
)"

# ---------------------------------------------------------------------------
# 8. --malicious: 무해한 canary 페이로드
# ---------------------------------------------------------------------------
if [ "$MALICIOUS" -eq 1 ]; then
  CANARY="$OUT/canary"
  PAY="$OUT/payloads"
  mkdir -p "$CANARY" "$PAY/hooks"

  # mkpayload <파일> <canary 이름> <canary 기록 후 실행할 셸 한 줄>
  mkpayload() {
    local file="$1" id="$2" tail="$3"
    {
      printf '#!/bin/sh\n'
      printf '# Overgrove fixture payload (harmless): records that it ran, nothing else.\n'
      printf "printf '%%s\\\\n' \"\$*\" >> '%s/%s'\n" "$CANARY" "$id"
      printf '%s\n' "$tail"
    } > "$file"
    chmod +x "$file"
  }

  mkpayload "$PAY/t1-fsmonitor.sh"   "T1-fsmonitor"            'exit 1'
  for h in post-index-change reference-transaction post-checkout post-merge pre-auto-gc post-rewrite pre-commit; do
    mkpayload "$PAY/hooks/$h"        "T2-hook-$h"              'cat >/dev/null 2>&1 || true; exit 0'
  done
  # T2: 설정형 hook (git 2.54+). 이전 git 은 hook.* 키를 무시한다.
  mkpayload "$PAY/t2-config-hook.sh" "T2-config-hook"          'cat >/dev/null 2>&1 || true; exit 0'
  mkpayload "$PAY/t3-textconv.sh"    "T3-textconv"             'cat "$1"'
  mkpayload "$PAY/t3-extdiff.sh"     "T3-external-diff"        'exit 0'
  mkpayload "$PAY/t4-clean.sh"       "T4-filter-clean"         'cat'
  mkpayload "$PAY/t4-smudge.sh"      "T4-filter-smudge"        'cat'
  mkpayload "$PAY/t4-process.sh"     "T4-filter-process"       'exit 1'
  mkpayload "$PAY/t5-ssh.sh"         "T5-sshCommand"           'exit 1'
  mkpayload "$PAY/t5-proxy.sh"       "T5-gitProxy"             'exit 1'
  mkpayload "$PAY/t5-uploadpack.sh"  "T5-uploadpack"           'exit 1'
  mkpayload "$PAY/t5-altrefs.sh"     "T5-alternateRefsCommand" 'exit 0'
  mkpayload "$PAY/t6-credential.sh"  "T6-credential-helper"    'exit 0'
  mkpayload "$PAY/t6-askpass.sh"     "T6-askpass"              'printf "\n"'
  mkpayload "$PAY/t7-gpg.sh"         "T7-gpg-program"          'exit 1'

  # T8: pack 을 2개로 만들어 두고 gc.autoPackLimit=1 을 설정하면 fetch 끝의 auto gc/maintenance 가 반드시 돈다.
  #     (pack 개수가 1개로 합쳐지면 의도치 않은 쓰기가 일어난 것)
  git repack -q -d

  # T7: 가짜 서명이 붙은 커밋 (설정 적용 전에 만들어야 hook 이 돌지 않는다)
  tree="$(git rev-parse 'main^{tree}')"
  parent="$(git rev-parse main)"
  signed="$(
    printf 'tree %s\nparent %s\nauthor Alice Example <alice@example.invalid> %s +0000\ncommitter Alice Example <alice@example.invalid> %s +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n fixture-not-a-real-signature\n -----END PGP SIGNATURE-----\n\nfixture: commit with a fake signature\n' \
      "$tree" "$parent" "$BASE_TS" "$BASE_TS" | git hash-object -t commit -w --stdin
  )"
  git update-ref refs/heads/malicious/signed "$signed"
  git repack -q -d    # 서명 커밋 등 남은 loose 객체로 두 번째 pack 생성

  # T5: alternates (fetch 시 core.alternateRefsCommand 가 쓰이는 조건)
  printf '%s\n' "$REM/upstream.git/objects" > "$(git rev-parse --git-common-dir)/objects/info/alternates"

  # T3 의 diff.external 은 include 된 파일에만 둔다 (검사기가 include 를 따라가는지 확인용)
  cat > "$PAY/included.config" <<EOF
[diff]
	external = $PAY/t3-extdiff.sh
EOF

  GC="$(git rev-parse --git-common-dir)"
  cat > "$GC/info/attributes" <<'EOF'
*.txt diff=fixture filter=fixture
*.md filter=fixtureproc
EOF

  # 설정 적용 (이후로는 이 스크립트에서 git 을 부르지 않는다)
  {
    printf '[core]\n'
    printf '\tfsmonitor = %s\n'           "$PAY/t1-fsmonitor.sh"
    printf '\thooksPath = %s\n'           "$PAY/hooks"
    printf '\tsshCommand = %s\n'          "$PAY/t5-ssh.sh"
    printf '\tgitProxy = %s\n'            "$PAY/t5-proxy.sh"
    printf '\talternateRefsCommand = %s\n' "$PAY/t5-altrefs.sh"
    printf '\taskPass = %s\n'             "$PAY/t6-askpass.sh"
    printf '[include]\n\tpath = %s\n'     "$PAY/included.config"
    printf '[diff "fixture"]\n\ttextconv = %s\n' "$PAY/t3-textconv.sh"
    printf '[filter "fixture"]\n\tclean = %s\n\tsmudge = %s\n' "$PAY/t4-clean.sh" "$PAY/t4-smudge.sh"
    printf '[filter "fixtureproc"]\n\tprocess = %s\n' "$PAY/t4-process.sh"
    printf '[remote "origin"]\n\tuploadpack = %s\n' "$PAY/t5-uploadpack.sh"
    printf '[remote "sshremote"]\n\turl = ssh://fixture.invalid/overgrove.git\n\tfetch = +refs/heads/*:refs/remotes/sshremote/*\n'
    printf '[remote "gitremote"]\n\turl = git://fixture.invalid/overgrove.git\n\tfetch = +refs/heads/*:refs/remotes/gitremote/*\n'
    printf '[remote "extremote"]\n\turl = ext::sh -c touch%% %s/T5-ext-transport\n\tfetch = +refs/heads/*:refs/remotes/extremote/*\n' "$CANARY"
    printf '[remote "redirected"]\n\turl = https://fixture-redirect.invalid/overgrove.git\n\tfetch = +refs/heads/*:refs/remotes/redirected/*\n'
    printf '[url "ssh://fixture.invalid/"]\n\tinsteadOf = https://fixture-redirect.invalid/\n'
    printf '[credential]\n\thelper = %s\n' "$PAY/t6-credential.sh"
    printf '[gpg]\n\tprogram = %s\n' "$PAY/t7-gpg.sh"
    printf '[log]\n\tshowSignature = true\n'
    printf '[gc]\n\tauto = 1\n\tautoPackLimit = 1\n\tautoDetach = false\n'
    printf '[maintenance]\n\tauto = true\n'
    printf '[hook "fixture"]\n\tcommand = %s\n' "$PAY/t2-config-hook.sh"
    for e in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg \
      commit-msg post-commit pre-rebase post-checkout post-merge pre-push pre-receive update proc-receive \
      post-receive post-update reference-transaction push-to-checkout pre-auto-gc post-rewrite \
      sendemail-validate fsmonitor-watchman post-index-change; do
      printf '\tevent = %s\n' "$e"
    done
  } >> "$GC/config"

  # T4: 내용은 같고 mtime 만 바뀐 추적 파일 → 다음 status 가 clean 필터로 내용을 다시 해시한다
  touch src/filter-target.txt
fi

if [ "$QUIET" -eq 1 ]; then
  echo "$OUT"
else
  echo "Overgrove fixture created: $OUT"
  [ "$MALICIOUS" -eq 1 ] && echo "mode: MALICIOUS (canary: $OUT/canary — must stay empty under Overgrove's git arguments)"
  echo
  echo "$SUMMARY"
fi
