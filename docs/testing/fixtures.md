# 테스트 픽스처 명세

> 상태: Accepted (Phase 2 게이트, 2026-11-05) · 관련: [test-strategy.md](test-strategy.md), [security-review.md](../design/security-review.md), [parsing-spec.md](../architecture/parsing-spec.md), [git-command-catalog.md](../architecture/git-command-catalog.md)

통합 테스트(`INT-xx`)와 보안 테스트(`SEC-Tn-xx`)는 [`scripts/make-fixture-repo.sh`](../../scripts/make-fixture-repo.sh)가 만든 저장소를 쓴다. 이 문서는 픽스처에 무엇이 있는지, 각 상태에서 파서가 무엇을 내야 하는지, 어떤 테스트가 그 상태를 검증하는지를 정의한다.

모든 출력 예시는 실제로 스크립트를 실행해 얻은 값이다. 실행 환경은 Apple Silicon M-series, macOS 26.6, `/usr/bin/git` 2.50.1 (Apple Git-155)이다.

---

## 1. 사용법

```sh
scripts/make-fixture-repo.sh <dir>               # 일반 픽스처
scripts/make-fixture-repo.sh --malicious <dir>   # 일반 픽스처 + 무해한 canary 페이로드
scripts/make-fixture-repo.sh --quiet <dir>       # 요약 없이 마지막 줄에 경로만 출력 (테스트용)
scripts/make-fixture-repo.sh --force <dir>       # 비어 있지 않은 <dir>을 지우고 다시 생성
```

| 항목 | 값 |
|---|---|
| 생성 시간 | 일반 약 2.1초, `--malicious` 약 2.3초 (M1 Pro) |
| 의존성 | bash 3.2 이상, git 2.36 이상. 그 외 도구 없음 |
| 격리 | 생성 중에는 `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`로 사용자 설정(서명, 훅, 별칭)을 차단한다 |
| 결정성 | 작성자, 커미터, 날짜를 커밋마다 고정한다. 같은 입력이면 커밋 SHA가 항상 같다. 두 번 생성해 모든 ref의 SHA 해시가 일치함을 확인했다 |
| 경로 의존 값 | 원격 URL, 페이로드 경로, 워크트리 gitdir 파일만 `<dir>`에 따라 달라진다. 그래서 픽스처 디렉터리를 복사해서 재사용하지 않는다 |

### 1.1 출력 구조

```
<dir>/
├── remotes/
│   ├── origin.git          bare. main, feat/ahead, feat/behind, feat/diverged, feat/remote-only
│   └── upstream.git        bare. main (+ upstream 전용 커밋 1개)
├── repo/                   메인 워크트리. branch main, WIP 상태 전부
├── worktrees/
│   ├── wt-ahead            feat/ahead      ahead 2
│   ├── wt-behind           feat/behind     behind 2
│   ├── wt-diverged         feat/diverged   ahead 1 · behind 1, 미추적 1
│   ├── wt-no-upstream      feat/no-upstream  upstream 없음
│   ├── wt-conflict         fix/conflict    병합 충돌 중 (UU, AA, DU)
│   ├── wt-locked           chore/locked    locked ("fixture: locked on purpose")
│   ├── wt-detached         detached HEAD (main~2)
│   └── (wt-prunable)       spike/prunable  디렉터리 삭제됨 → prunable
├── canary/                 --malicious 일 때만. 비어 있어야 정상
└── payloads/               --malicious 일 때만. canary 를 남기는 무해한 sh 스크립트
```

---

## 2. 이력과 참조

### 2.1 커밋 그래프 (main 기준, `--exclude=refs/stash --all` 21개)

```
* e4bd61e feat: local-only change on main              (main, origin/main 보다 1개 앞)
* 0893a1a docs: update manual                          (origin/main, chore/locked, spike/prunable)
* c46c37d docs: rename guide to manual                 (wt-detached 의 HEAD = main~2)
*   0cbcd45 Merge branch 'feat/merged'                 (병합 커밋, 부모 2개)
|\
| * b134225 feat: merged work 2                        (feat/merged)
| * ba37fbe feat: merged work 1
* | 337f477 fix: tweak readme                          (v0.0.1 주석 태그)
|/
* 4202323 feat: add guide details and update binary    (light-tag 경량 태그, 바이너리 변경)
* 0c53f8b chore: initial fixture content               (루트 커밋)
```

나머지 브랜치는 모두 `0893a1a`에서 갈라진다. 작성자는 `Alice Example`, `Bob Example`, `김개발` 세 명이 번갈아 나온다. 비 ASCII 작성자 이름은 PAR-LOG-03에서 쓴다.

### 2.2 브랜치와 upstream

| 브랜치 | upstream | 기대 ahead/behind | 워크트리 | 관련 테스트 |
|---|---|---|---|---|
| `main` | `origin/main` | +1 / -0 | `repo/` | PAR-STATUS-01, INT-04 |
| `feat/ahead` | `origin/feat/ahead` | +2 / -0 | `wt-ahead` | INT-04 |
| `feat/behind` | `origin/feat/behind` | +0 / -2 | `wt-behind` | INT-04 |
| `feat/diverged` | `origin/feat/diverged` | +1 / -1 | `wt-diverged` | INT-04 |
| `feat/no-upstream` | 없음 | 표시 안 함 | `wt-no-upstream` | PAR-STATUS-05, PAR-REF-05, INT-04 |
| `fix/conflict` | 없음 | 표시 안 함 | `wt-conflict` | INT-03 |
| `chore/locked` | 없음 | — | `wt-locked` | PAR-WT-03 |
| `spike/prunable` | 없음 | — | (삭제됨) | PAR-WT-04 |
| `feat/merged` | 없음 | — | 없음 | PAR-LOG-02 |
| `topic/conflict-other` | 없음 | — | 없음 | INT-03 |
| `feat/remote-only` | — | — | origin에만 있음. 로컬 추적 ref 없음 | INT-12 |

### 2.3 그 밖의 참조

| 참조 | 내용 | 관련 테스트 |
|---|---|---|
| `v0.0.1` | 주석 태그 (`337f477`을 가리킴) | PAR-REF-02 |
| `light-tag` | 경량 태그 (`4202323`) | PAR-REF-01 |
| `refs/remotes/upstream/main` | `5606cda chore: upstream-only change` (로컬에 없는 커밋) | INT-04, INT-11 |
| `refs/remotes/upstream/HEAD` | `refs/remotes/upstream/main`을 가리키는 symref. git 2.48 이상의 fetch가 자동으로 만든다. `origin/HEAD`는 없다 (push로만 채웠기 때문) | PAR-REF-03 |
| `refs/stash` | stash 2개 (§2.4) | PAR-STASH-01, INT-05 |
| 원격 `mirror` | `https://<user>:<pass>@example.invalid/overgrove-fixture.git`. 사용자명과 비밀번호는 스크립트가 런타임에 조합한 가짜 값이다. `remote.mirror.skipFetchAll=true` | SEC-T11-01, SEC-T11-04, INT-13 |

### 2.4 stash

| 항목 | 메시지 (`%gs`) | 내용 | 관련 테스트 |
|---|---|---|---|
| `stash@{0}` | `On feat/ahead: fixture: with untracked` | 추적 파일 1개 수정 + 미추적 파일 1개 (`-u`). `--include-untracked` numstat에 `stash-untracked.txt`가 나온다 | PAR-STASH-01, PAR-NUMSTAT-05, INT-05 |
| `stash@{1}` | `On main: fixture: tracked change` | `src/stash-target.txt` 1줄 추가 | PAR-STASH-01, INT-06 |

**주의 (실측).** `git log --all`은 `refs/stash`를 따라가므로 stash 커밋과 그 index·untracked 부모 커밋이 그래프에 섞인다. 그래서 `--all`로 세면 24개, `--exclude=refs/stash --all`로 세면 21개다. 병합 커밋 수도 `--all`이면 2개(stash 커밋 포함), 제외하면 1개다. 그래프 조회는 반드시 `--exclude=refs/stash`를 쓴다 (ADR-0010, INT-07).

---

## 3. 워크트리

`git worktree list --porcelain -z`의 실측 결과는 9개 레코드다. NUL은 줄바꿈으로 바꿔 보였다.

| 워크트리 | porcelain 속성 | 기대 `Worktree` 모델 | 관련 테스트 |
|---|---|---|---|
| `repo/` | `branch refs/heads/main` | 메인 워크트리, 브랜치 `main` | PAR-WT-01, INT-01 |
| `wt-ahead` | `branch refs/heads/feat/ahead` | 일반 | PAR-WT-01 |
| `wt-behind` | `branch refs/heads/feat/behind` | 일반 | INT-01 |
| `wt-conflict` | `branch refs/heads/fix/conflict` | 일반, 상태 조회 시 충돌 3건 | INT-03 |
| `wt-detached` | `detached` | `isDetached = true`, HEAD `c46c37d` | PAR-WT-02, PAR-STATUS-03, INT-16 |
| `wt-diverged` | `branch refs/heads/feat/diverged` | 일반, 미추적 1건 (`notes.txt`) | INT-04 |
| `wt-locked` | `locked fixture: locked on purpose` | `lock = .locked(reason: "fixture: locked on purpose")` | PAR-WT-03, INT-15 |
| `wt-no-upstream` | `branch refs/heads/feat/no-upstream` | upstream 없음 | PAR-STATUS-05 |
| `wt-prunable` | `prunable gitdir file points to non-existent location` | `prunable = .yes(reason: …)`. 경로가 없으므로 status를 조회하지 않는다 | PAR-WT-04, INT-14 |

워크트리별 status 요약 (실측):

```
repo                       staged=6 unstaged=8 untracked=6 conflicted=0
worktrees/wt-ahead         staged=0 unstaged=0 untracked=0 conflicted=0   (stash@{0} 로 변경을 치움)
worktrees/wt-behind        staged=0 unstaged=0 untracked=0 conflicted=0
worktrees/wt-conflict      staged=0 unstaged=0 untracked=0 conflicted=3
worktrees/wt-detached      staged=0 unstaged=0 untracked=0 conflicted=0
worktrees/wt-diverged      staged=0 unstaged=0 untracked=1 conflicted=0
worktrees/wt-locked        staged=0 unstaged=0 untracked=0 conflicted=0
worktrees/wt-no-upstream   staged=0 unstaged=0 untracked=0 conflicted=0
```

---

## 4. 메인 워크트리(`repo/`) WIP

`status --porcelain=v2 -z --branch --untracked-files=all` 실측 결과를 파일별로 정리했다. MM처럼 양쪽에 걸친 파일은 staged와 unstaged 목록에 모두 들어간다.

| 경로 | XY / 레코드 | 기대 분류 | 비고 | 관련 테스트 |
|---|---|---|---|---|
| `src/staged-modified.txt` | `1 M.` | staged: modified | | PAR-STATUS-01 |
| `src/staged-added.txt` | `1 A.` | staged: added | | PAR-STATUS-01 |
| `src/staged-deleted.txt` | `1 D.` | staged: deleted | | PAR-STATUS-01 |
| `src/new-name.txt` ← `src/old-name.txt` | `2 R. … R100` + 원래 경로 레코드 | staged: renamed (score 100) | `-z`에서는 새 경로 다음 NUL 필드가 원래 경로다 | PAR-STATUS-08 |
| `src/staged-and-unstaged.txt` | `1 MM` | staged + unstaged | | PAR-STATUS-07 |
| `src/unstaged-modified.txt` | `1 .M` | unstaged: modified | | PAR-STATUS-01 |
| `src/unstaged-deleted.txt` | `1 .D` | unstaged: deleted | | PAR-STATUS-01 |
| `src/typechange` | `1 .T` (mH `120000` → mW `100644`) | unstaged: type changed | 심볼릭 링크 → 일반 파일 | PAR-STATUS-12 |
| `scripts/run.sh` | `1 .M` (mI `100644`, mW `100755`) | unstaged: modified (모드 변경) | 해시는 같고 모드만 다르다 | INT-17 |
| `intent.txt` | `1 .A` (mH `000000`, mI `000000`) | unstaged: added (intent-to-add) | `git add -N` | INT-17 |
| `line⏎break.txt` | `1 M.` | staged: modified | 파일명에 개행 | PAR-STATUS-10 |
| `with space.txt` | `1 .M` | unstaged: modified | 파일명에 공백 | PAR-STATUS-10 |
| `-dash-leading.txt` | `1 .M` | unstaged: modified | `-`로 시작. diff 호출 시 `--` 뒤에 둬야 한다 | PAR-STATUS-10, SEC-T9-03 |
| `untracked.txt` | `?` | untracked | | PAR-STATUS-01 |
| `untracked dir/nested.txt` | `?` | untracked | `--untracked-files=all`이라 디렉터리가 아니라 파일로 나온다 | PAR-STATUS-01 |
| `tab⇥here.txt` | `?` | untracked | 파일명에 탭 | PAR-STATUS-10 |
| `été.txt` (디스크에는 NFD) | `?` | untracked | **git이 NFC로 바꿔서 출력한다** (§5) | PAR-STATUS-10 |
| `한글 파일.txt` | `?` | untracked | 한글과 공백 | PAR-STATUS-10 |
| `--option-like.txt` | `?` | untracked | `--`로 시작 | PAR-STATUS-10, SEC-T9-03 |
| `debug.log` | (나오지 않음) | — | `.gitignore`의 `*.log`. 기본 status에 나오면 안 된다 | INT-18 |

헤더 실측값은 다음과 같다.

```
# branch.oid e4bd61e…
# branch.head main
# branch.upstream origin/main
# branch.ab +1 -0
```

### 4.1 `wt-conflict` 충돌 레코드

`topic/conflict-other`를 병합하다 멈춘 상태다.

| 경로 | 레코드 | 의미 | 관련 테스트 |
|---|---|---|---|
| `conflict.txt` | `u UU` | 양쪽 수정 | PAR-STATUS-09, INT-03 |
| `both-added.txt` | `u AA` | 양쪽 추가 | PAR-STATUS-09, INT-03 |
| `deleted-by-us.txt` | `u DU` | 우리 쪽 삭제, 상대 쪽 수정 | PAR-STATUS-09, INT-03 |

나머지 4가지 XY(`DD`, `AU`, `UA`, `UD`)는 픽스처에 없다. PAR-STATUS-09에서 문자열 입력으로 검증한다.

---

## 5. 특수 파일명

| 파일명 | 위치 | 확인하려는 것 |
|---|---|---|
| `with space.txt`, `dir with space/file.txt`, `한글 파일.txt` | 커밋 / 미추적 | 공백 |
| `line⏎break.txt` | 커밋 + staged 변경 | 개행. `-z`가 아니면 C 스타일 따옴표로 바뀌는 경로 |
| `tab⇥here.txt` | 미추적 | 탭 |
| `-dash-leading.txt`, `--option-like.txt` | 커밋 / 미추적 | 옵션으로 오인되는 이름 (T9) |
| `quote"double.txt`, `it's.txt`, `back\slash.txt` | 커밋 | 따옴표, 역슬래시 |
| `café.txt` (NFC) | 커밋 | NFC |
| `été.txt` (NFD로 생성) | 미추적 | NFD |
| `emoji-🌲.txt` | 커밋 | 4바이트 UTF-8 |

**유니코드 정규화 실측.** macOS에서 `git init`은 저장소 설정에 `core.precomposeunicode=true`를 넣는다. 이 상태에서 디스크에 NFD(`65 cc 81`)로 만든 `été.txt`를 git은 NFC(`c3 a9`)로 바꿔서 출력한다. `-c core.precomposeunicode=false`를 주면 NFD 바이트가 그대로 나온다.

따라서 다음이 성립한다.
- PAR-STATUS-10의 기대값은 NFC 바이트다 (기본 설정 기준).
- "git이 준 바이트를 그대로 git에 되돌려 준다"는 parsing-spec의 원칙은 이 설정에서도 안전하다. APFS가 정규화를 구분하지 않고 조회하기 때문이다.
- 파일 시스템에서 직접 연 경로와 git이 준 경로를 바이트로 비교하면 다를 수 있다 (S-10 Diff 뷰어, PathValidator).

---

## 6. 이력 조회용 데이터

| 시나리오 | 픽스처 데이터 | 기대 결과 | 관련 테스트 |
|---|---|---|---|
| 루트 커밋 | `0c53f8b` | `%P` 비어 있음 | PAR-LOG-01 |
| 병합 커밋 | `0cbcd45` | 부모 2개 | PAR-LOG-02, GRA-02 |
| 바이너리 numstat | `4202323` | `assets/binary.bin` → `-` `-` | PAR-NUMSTAT-03, INT-08 |
| 이름 변경 numstat | `c46c37d` | `docs/guide.md` → `docs/manual.md` (`-z`에서는 빈 경로 필드 뒤 두 경로) | PAR-NUMSTAT-02, INT-08 |
| 파일 이력 `--follow` | `docs/manual.md` | 4개: `0893a1a`, `c46c37d`(이름 변경), `4202323`, `0c53f8b` | INT-09 |
| stash numstat (untracked 포함) | `stash@{0}` | `branches/feat-ahead.txt 1 0`, `stash-untracked.txt 1 0` | PAR-NUMSTAT-05, INT-05 |
| fetch로 새 ref | origin의 `feat/remote-only` | fetch 뒤 `refs/remotes/origin/feat/remote-only` 생성 | INT-12 |

---

## 7. 통합 테스트 목록 (INT)

| ID | 내용 | 픽스처 |
|---|---|---|
| INT-01 | `worktree list` → 9개, 메인 1개, locked·prunable·detached 각 1개 | 일반 |
| INT-02 | 메인 워크트리 status 분류 개수 (staged 6, unstaged 8, untracked 6, conflicted 0)와 §4 표 전체 일치 | 일반 |
| INT-03 | `wt-conflict` 충돌 3건과 XY 일치 | 일반 |
| INT-04 | 브랜치별 ahead/behind (§2.2). upstream 없는 브랜치는 `nil` | 일반 |
| INT-05 | stash 2개의 순서, 메시지, 브랜치, `stash@{0}`의 untracked 포함 numstat | 일반 |
| INT-06 | `stash show --numstat stash@{1}` | 일반 |
| INT-07 | 그래프 첫 페이지에 stash 커밋이 없음 (21개), 병합 커밋 부모 2개 | 일반 |
| INT-08 | 커밋 상세 numstat: 바이너리, 이름 변경 | 일반 |
| INT-09 | `docs/manual.md` 파일 이력 4개 (이름 변경 이전 포함) | 일반 |
| INT-10 | §5의 모든 특수 파일명으로 diff·파일 이력을 조회해 해당 파일만 대상이 됨 (`--literal-pathspecs`, `--`) | 일반 |
| INT-11 | `for-each-ref`: 로컬 10개, 원격 추적 ref, 태그 2개(주석 태그 peel), `upstream/HEAD` symref | 일반 |
| INT-12 | fetch 후 `origin/feat/remote-only`가 나타나고 마지막 fetch 시각이 갱신됨 | 일반 |
| INT-13 | 원격 `mirror` URL이 UI 모델에서 마스킹됨 | 일반 |
| INT-14 | prunable 워크트리: 경로 없음을 표시하고 status를 호출하지 않음 | 일반 |
| INT-15 | locked 워크트리의 이유 문자열 표시 | 일반 |
| INT-16 | detached HEAD 워크트리: `# branch.head (detached)`, upstream 없음 | 일반 |
| INT-17 | intent-to-add `.A`, 타입 변경 `.T`, 모드만 바뀐 `.M` 분류 | 일반 |
| INT-18 | 무시된 파일(`debug.log`)이 목록에 없음 | 일반 |
| INT-19 | 모든 조회 명령을 실행한 뒤 `canary/`가 비어 있음 (SEC 묶음 실행기) | 악성 |
| INT-20 | git 최소 버전 검사: 현재 git 버전 파싱 성공 (PAR-VER-01의 실환경판) | 없음 |

---

## 8. `--malicious` 페이로드

### 8.1 심는 내용

모든 페이로드는 `printf '%s\n' "$*" >> '<dir>/canary/<ID>'` 한 줄로 실행 사실만 남긴다. 네트워크나 다른 파일에는 손대지 않는다. 생성 직후 `canary/`는 비어 있다.

| ID (canary 파일명) | 위협 | 심는 방법 | 실행 조건 |
|---|---|---|---|
| `T1-fsmonitor` | T1 | `core.fsmonitor = payloads/t1-fsmonitor.sh` | index를 읽는 명령 (status, diff) |
| `T2-hook-<name>` | T2 | `core.hooksPath = payloads/hooks/` (`post-index-change`, `reference-transaction`, `post-checkout`, `post-merge`, `pre-auto-gc`, `post-rewrite`, `pre-commit`) | index 쓰기, ref 갱신(fetch), auto gc |
| `T3-textconv` | T3 | `diff.fixture.textconv` + `.git/info/attributes`의 `*.txt diff=fixture` | patch 출력 (`diff`, `show -p`) |
| `T3-external-diff` | T3 | `diff.external`. **`include.path`로 불러온 파일에만 있다** | `git diff` |
| `T4-filter-clean` | T4 | `filter.fixture.clean` + `*.txt filter=fixture`. 생성 마지막에 `src/filter-target.txt`의 mtime만 바꾼다 | 워크트리 내용을 다시 해시할 때 (status, 워크트리 diff) |
| `T4-filter-smudge` | T4 | `filter.fixture.smudge` | 워크트리용 내용 변환 (`show -p`의 textconv 경로 등) |
| `T4-filter-process` | T4 | `filter.fixtureproc.process` + `*.md filter=fixtureproc` | long-running 필터를 쓰는 변환 |
| `T5-sshCommand` | T5 | `core.sshCommand` + 원격 `sshremote` (`ssh://fixture.invalid/…`) | ssh 원격 fetch |
| `T5-sshCommand` (경유) | T5 | 원격 `redirected` (`https://fixture-redirect.invalid/…`) + `url."ssh://fixture.invalid/".insteadOf` | https로 보이는 원격 fetch가 ssh로 바뀜 |
| `T5-gitProxy` | T5 | `core.gitProxy` + 원격 `gitremote` (`git://…`) | git 프로토콜 fetch |
| `T5-uploadpack` | T5 | `remote.origin.uploadpack` | 로컬 경로 원격(origin) fetch |
| `T5-alternateRefsCommand` | T5 | `core.alternateRefsCommand` + `objects/info/alternates`(→ `upstream.git/objects`) | **alternates가 있는 저장소의 fetch** |
| `T5-ext-transport` | T5 | 원격 `extremote` (`ext::sh -c touch% …`) | `protocol.ext.allow`가 열려 있을 때 fetch |
| `T6-credential-helper` | T6 | `credential.helper = payloads/t6-credential.sh` | HTTP 인증이 필요할 때 |
| `T6-askpass` | T6, T12 | `core.askPass` | 인증 입력이 필요할 때 |
| `T7-gpg-program` | T7 | `gpg.program` + `log.showSignature=true` + 가짜 서명 커밋 `malicious/signed` | 서명 커밋이 포함된 log·show |
| (canary 없음) | T8 | `gc.auto=1`, `gc.autoPackLimit=1`, `maintenance.auto=true`, pack 2개 | fetch 끝의 auto maintenance. 판정은 `GIT_TRACE`로 한다 (§8.3) |

`--malicious`는 일반 픽스처 위에 덧붙인다. 그래서 일반 픽스처와 달라지는 점은 다음뿐이다.
- 브랜치 `malicious/signed`
- 원격 `sshremote`, `gitremote`, `extremote`, `redirected`
- pack 파일 2개, `objects/info/alternates`
- `.git/info/attributes`

**설정을 덮어쓰는 위치.** 신뢰할 수 없는 저장소는 보통 `.git/config`를 클론으로 받지 않는다. 대신 압축 파일, 공유 디렉터리, 다른 도구나 다른 사용자가 수정한 저장소처럼 이미 디스크에 있는 `.git`이 위협 모델이다 ([security-review.md §1.3](../design/security-review.md)). `.gitattributes`는 커밋되는 파일이지만, 픽스처는 기대 결과가 일반 모드와 같도록 같은 효과의 `.git/info/attributes`를 쓴다.

### 8.2 실측 결과 (명령 × 인자 조합)

케이스마다 픽스처를 새로 만들었다. git은 `/usr/bin/git` 2.50.1이다. 열의 의미는 다음과 같다.
- **plain**: 보안 인자 없음 (일반 GUI 클라이언트 상황)
- **base**: HANDOFF §6.2 원안. `-c core.fsmonitor=false -c core.hooksPath=/dev/null`, `LC_ALL=C`, `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`. diff 계열에는 `--no-ext-diff --no-textconv`
- **hardened**: base에 [git-command-catalog §2](../architecture/git-command-catalog.md)의 공통 인자와 동적 무력화 인자를 더하고, `-c core.alternateRefsCommand=`를 추가한 것

| # | 명령 | plain | base | hardened |
|---|---|---|---|---|
| M01–03 | `status --porcelain=v2 -z --branch --untracked-files=all` | T1, T2(post-index-change), T4-clean | **T4-clean** | 없음 |
| M04–06 | `diff` (워크트리) | T1, T2, T3-external, T4-clean, T4-smudge | **T4-clean** | 없음 |
| M07 | `diff --cached` | — | 없음 | — |
| M08 | `diff --numstat` (워크트리) | T1, T2, T4-clean (textconv·external 없음) | — | — |
| M09–10 | `show -p HEAD` | T3-textconv, T4-smudge | 없음 | — |
| M11 | `stash show -p stash@{1}` | 없음 (기본으로 textconv를 쓰지 않음) | — | — |
| M12–14 | `log --all --date-order -z --format=…` | T7 | **T7** (`log.showSignature=true` 때문) | 없음 |
| M15 | `log --format=%H%G?` | — | — | **T7** (`showSignature=false`여도 실행됨) |
| M16–19 | `worktree list`, `for-each-ref`, `rev-list @{u}...HEAD`, `stash list` | — | 없음 | — |
| M20–22 | `fetch origin` | T1, T5-uploadpack | **T5-uploadpack** | **T5-uploadpack** (`-c remote.origin.uploadpack=…`는 무시됨) |
| M23 | `fetch --upload-pack=git-upload-pack origin` | T1, T2(pre-auto-gc, reference-transaction), T5-alternateRefs, auto maintenance | — | — |
| M24 | 같은 명령 | — | **T5-alternateRefs, auto maintenance** | — |
| M25 | 같은 명령 + `--no-auto-maintenance` | — | **T5-alternateRefs** | — |
| M26 | 같은 명령 | — | — | 없음 |
| M27–28 | `fetch sshremote` | — | **T5-sshCommand** | 없음 |
| M29–30 | `fetch redirected` (`insteadOf` → ssh) | — | **T5-sshCommand** | 없음 |
| M31–33 | `fetch gitremote` | — | **T5-gitProxy** (`-c core.gitProxy=`로도 실행됨) | 없음 (`protocol` allowlist 또는 빈 `GIT_PROXY_COMMAND`) |
| M34 | `fetch extremote` | T1 (ext는 기본값 `never`로 차단됨) | — | — |
| M35–38 | `credential fill` (HTTP 인증 대용) | — | **T6-helper, T6-askpass** (`GIT_TERMINAL_PROMPT=0`이어도 askPass 실행) | 없음 |

**카탈로그 인자 그대로 재검증 (M26 보강).** `git-command-catalog.md`의 공통 인자, 환경 변수, `fetch(remote:)` 인자를 그대로 쓰고 `core.alternateRefsCommand` 무력화만 뺐다. 이때 `T5-alternateRefsCommand`가 실행됐다. 여기에 `-c core.alternateRefsCommand=`(빈 값)를 더하면 실행되지 않았고 fetch는 성공했다. 빈 값 대신 `=true`로 해도 막힌다.

### 8.3 판정 방법

- **canary 판정.** 명령 실행 뒤 `<dir>/canary/`의 항목 수가 0이어야 한다. 파일 이름이 실행된 경로를 알려 준다.
- **T8 판정.** pack 개수 변화로는 판정하지 않는다.
  - 실측에서 auto gc가 돌아도 alternates가 있으면 pack 수가 그대로였다.
  - git 2.54(Homebrew)에서는 `maintenance run --auto`가 gc를 시작하지 않았다.
  - 그래서 `GIT_TRACE=<file>`로 실행하고, 자식 프로세스 목록에 `maintenance run`과 `gc --auto`가 없음을 확인한다.
  - `.git/packed-refs`와 `objects/pack/` 목록이 바뀌지 않았는지도 보조로 확인한다. auto maintenance는 `pack-refs --auto`도 실행한다.
  - 보안 테스트 실행기만 `GIT_TRACE`를 쓴다. 앱은 쓰지 않는다 (T10).
- **설정 읽기는 안전하다.** `git config --list --show-scope --show-origin`을 실행해도 canary가 생기지 않았다.
  - 단, `git config --local --list`는 **기본으로 include를 따라가지 않는다.** 그래서 `include.path`에만 있는 `diff.external`이 보이지 않았다.
  - 모든 scope를 한 번에 읽으면(`--list --show-scope`) include가 기본으로 켜지고, include된 값은 `local` scope로 보고된다.
  - RepoConfigInspector는 `--includes`를 명시하거나 전체 scope 조회를 써야 한다 (PAR-CONFIG-01).

---

## 9. 테스트 코드에서 쓰는 법

- 픽스처 생성은 `OvergroveTests/Support/FixtureRepo.swift`가 맡는다. 이곳은 CLAUDE.md가 허용한 테스트용 프로세스 실행 예외 위치다. 스크립트를 실행하고 마지막 줄의 경로를 받는다 (`--quiet`).
- 테스트 클래스마다 한 번 만들고(`override class func setUp`), 끝나면 지운다. 상태를 바꾸는 테스트(fetch, SEC 테스트)는 테스트마다 새로 만든다. 생성은 약 2초다.
- 경로는 `FileManager.default.temporaryDirectory` 아래 고유 디렉터리를 쓴다. 병렬 테스트끼리 디렉터리를 공유하지 않는다.
  - 고유 디렉터리(`overgrove-fixture-<UUID>/`) 안에 격리된 빈 HOME(`home/`)과 스크립트 출력(`fixture/`)을 둔다. 스크립트는 부모 환경을 상속하지 않고 `HOME=home/`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=home/.gitconfig`로 실행한다. git은 앱과 같은 것(`GitEnvironment.discover()`)을 `PATH` 맨 앞에 둔다.
  - 픽스처에 대해 `GitClient`를 쓸 때는 `parentEnvironment: fixture.environment`를 넘겨 실행 환경의 HOME이 섞이지 않게 한다.
  - `XCTestCase.makeFixture(malicious:)`는 정리를 teardown 블록으로 등록하므로 테스트가 실패하거나 throw해도 지워진다. 생성이 실패하면 `FixtureRepo.make`가 디렉터리를 지우고 오류를 던진다.
- 기대값은 이 문서의 표를 코드 상수로 옮긴다. SHA는 고정이므로 `e4bd61e` 같은 값을 직접 비교해도 된다. 단, git 버전에 따라 stash 커밋 메시지 형식이 달라질 수 있으므로 stash SHA는 비교하지 않는다.
- 픽스처 스크립트를 바꾸면 이 문서의 표와 테스트 상수를 같은 PR에서 고친다.

## 10. 확장 규칙

1. 상태를 추가하면 §2–§6 표와 §7 INT 목록에 행을 추가하고 테스트 ID를 붙인다.
2. 결정성을 깨지 않는다. 시각, 난수, 사용자 설정에 의존하지 않는다. 커밋을 만드는 명령 앞에는 항상 `tick`을 부른다.
3. 실제 비밀처럼 보이는 문자열을 스크립트에 쓰지 않는다. 필요하면 런타임에 조합한다. 스크립트는 gitleaks 검사를 통과해야 한다 (확인함).
4. 페이로드는 canary 기록 외의 일을 하지 않는다. 네트워크 접근, 파일 삭제, 저장소 밖 쓰기는 금지한다.
5. 서브모듈(PAR-STATUS-11, SEC-T1-02, SEC-T4-05)과 SHA-256 저장소(PAR-LOG-04)는 아직 픽스처에 없다. Phase 3에서 `--with-submodule`, `--sha256` 옵션으로 추가한다 (later 아님, Phase 3 이슈).
