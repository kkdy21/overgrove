# 파싱 명세

> 상태: Accepted (Phase 2 게이트, 2026-11-05) · 관련: ADR-0008, ADR-0010, [git-command-catalog.md](git-command-catalog.md), [../testing/test-strategy.md](../testing/test-strategy.md)

이 문서는 [git-command-catalog.md](git-command-catalog.md)에 있는 명령의 출력 형식과 파서 규칙을 정의한다. 형식 예시는 Apple Git 2.50.1과 gh 2.95.0에서 실제로 얻은 출력이다. NUL 바이트는 `␀`로 표시한다.

---

## 1. 공통 규칙

1. **입력은 바이트다.** 파서는 `Data`를 받는다. git 출력을 미리 `String`으로 바꾸지 않는다.
2. **구분자.** `-z` 출력은 NUL로 토큰을 나눈다. 필드 사이 구분자도 NUL(`%x00`, `%00`)을 쓴다. 공백이나 탭으로 나누는 경우는 형식이 고정된 필드(모드, OID, 숫자)뿐이다. 경로는 항상 남은 부분 전체로 읽는다.
3. **경로 타입.** 경로는 `GitPath { raw: Data, display: String, isRepresentable: Bool }`로 다룬다.
   - `raw`가 올바른 UTF-8이면 `display = String(decoding:)`, `isRepresentable = true`
   - 아니면 손실 디코딩(U+FFFD)한 값을 `display`로 쓰고 `isRepresentable = false`
   - `Process.arguments`는 `[String]`이라서 `isRepresentable == false`인 경로는 git 인자로 되돌려 보낼 수 없다. 이런 파일은 목록에는 보이지만 diff·이력 같은 파일 단위 동작을 끈다.
4. **유니코드 정규화를 하지 않는다.** NFD와 NFC는 다른 경로로 취급하고, git이 준 바이트를 그대로 쓴다. 화면 정렬과 검색은 `localizedStandardCompare`와 정규화된 비교 키로 한다. 하지만 git에 되돌려 줄 때는 `raw`만 쓴다.
5. **잘린 출력.** `ProcessResult.truncated == true`면 마지막 레코드는 완전하지 않을 수 있으므로 버린다. 결과에 `isPartial = true`를 표시하고, UI는 "일부만 표시" 경고를 띄운다.
6. **알 수 없는 형식.**
   - 알 수 없는 헤더(`# ...`)와 속성은 무시한다. 상위 호환을 위해서다.
   - 알 수 없는 레코드 종류는 건너뛰고 `skippedRecords` 수를 올린다. 하나라도 있으면 UI에 비차단 경고를 띄운다.
   - 필드 수나 형식이 맞지 않으면(OID가 hex가 아님, 숫자 필드가 숫자가 아님 등) 해당 파서 전체를 `GitError.parseFailed(parser:offset:)`로 실패시킨다. 필드가 밀린 상태로 계속 읽으면 잘못된 정보를 보여 주게 되기 때문이다.
7. **OID 검증.** `^[0-9a-f]{40}$` (SHA-1) 또는 `^[0-9a-f]{64}$` (SHA-256).
8. **숫자.** 10진수 정수만 허용한다. 부호는 `branch.ab`의 `+`/`-` 접두사만 허용한다.
9. **성능.** 파서는 입력을 한 번만 훑는다(O(n)). 토큰마다 `Data` 사본을 만들지 않고 슬라이스를 쓴다. 10만 커밋 로그(약 15MB 기준) 파싱은 PERF 측정 대상이다.

---

## 2. WorktreeParser — `worktree list --porcelain -z`

**형식.** 속성 하나가 NUL로 끝나는 토큰 하나다. 레코드는 빈 토큰(연속된 NUL)으로 끝난다.

```
worktree <abs path>␀HEAD <oid>␀branch refs/heads/main␀␀
worktree <abs path>␀HEAD <oid>␀detached␀locked on usb␀␀
worktree <abs path>␀HEAD <oid>␀branch refs/heads/gone␀prunable gitdir file points to non-existent location␀␀
```

| 속성 | 의미 | 모델 |
|---|---|---|
| `worktree <path>` | 레코드 시작. 첫 레코드가 메인 워크트리 | `Worktree.path`, `isMain` |
| `HEAD <oid>` | 현재 커밋 | `head` |
| `branch <full ref>` | 체크아웃된 브랜치 | `branch` |
| `detached` | detached HEAD | `branch = nil`, `isDetached` |
| `bare` | bare 저장소 (메인만) | `isBare` |
| `locked[ <reason>]` | 잠김, 이유는 선택 | `lock: .locked(reason?)` |
| `prunable[ <reason>]` | 정리 필요 (경로 없음 등) | `prunable: reason?` |

- `-z` 덕분에 경로와 잠금 이유에 개행이 있어도 안전하다. `-z`는 git 2.36에서 들어왔고, 그 전에는 c-quote 문제가 있었다 (릴리스 노트 확인).
- unborn 브랜치 워크트리(빈 저장소의 메인, `--orphan` 워크트리)는 `HEAD`가 0으로 채워진 OID이고 `branch`는 그대로 나온다. 파서는 이를 `head = nil`로 바꾼다 (Apple Git 2.54.0 확인, PAR-WT-09).
- bare 메인 저장소 레코드에는 `HEAD`와 `branch`가 없고 `bare`만 있다 (확인, PAR-WT-05).
- 잘린 출력이면 마지막 레코드는 종료 NUL이 남아 있어도 버린다(§1.5). 잘리지 않았는데 마지막 레코드가 끝나지 않았으면 실패한다.

| 테스트 | 사례 |
|---|---|
| PAR-WT-01 | 메인 + 연결 워크트리 2개 |
| PAR-WT-02 | detached |
| PAR-WT-03 | locked (이유 있음/없음) |
| PAR-WT-04 | prunable (이유 포함) |
| PAR-WT-05 | bare 메인 저장소 |
| PAR-WT-06 | 경로에 공백·개행·NFD·이모지 |
| PAR-WT-07 | 잘린 출력 (마지막 레코드 버림) |
| PAR-WT-08 | 알 수 없는 속성 무시 |
| PAR-WT-09 | unborn 브랜치 워크트리 |

---

## 3. StatusParser — `status --porcelain=v2 -z --branch --show-stash --untracked-files=all --ignore-submodules=dirty`

### 3.1 헤더

```
# branch.oid 512402bf…␀# branch.head main␀# branch.upstream origin/main␀# branch.ab +1 -0␀# stash 2␀
```

| 헤더 | 값 | 비고 |
|---|---|---|
| `# branch.oid` | OID 또는 `(initial)` | `(initial)`이면 커밋이 없는 브랜치 (확인) |
| `# branch.head` | 브랜치 짧은 이름 또는 `(detached)` | (확인) |
| `# branch.upstream` | `origin/main` 형식 | upstream이 없으면 헤더가 없음 |
| `# branch.ab` | `+<ahead> -<behind>` | upstream이 설정되어 있어도 원격 추적 ref가 사라졌으면 헤더가 없다 → `UpstreamStatus.gone` (확인) |
| `# stash` | stash 개수 | 개수가 0이면 헤더가 없음. git 2.35+ (확인) |

### 3.2 레코드

| 접두사 | 형식 (필드는 공백 하나로 구분, 마지막 경로는 나머지 전체) |
|---|---|
| `1` | `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>` |
| `2` | `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>␀<origPath>` |
| `u` | `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>` |
| `?` | `? <path>` |
| `!` | `! <path>` (`--ignored`를 쓰지 않으므로 나오지 않음, 나오면 무시) |

- `2` 레코드에서 `-z` 출력은 **새 경로가 먼저, 원래 경로가 다음 토큰**이다 (확인: `R100 renamed.txt␀:(exclude)x␀`).
- `<sub>`는 서브모듈이 아니면 `N...`, 서브모듈이면 `S<c><m><u>`이다 (예: `S.M.`, `SC..`). `--ignore-submodules=dirty`이면 서브모듈 내부 변경(`m`, `u`)은 나오지 않고 커밋 변경(`C`)만 나온다 (확인).

### 3.3 분류 규칙

`XY`에서 `X`는 index 상태, `Y`는 작업 트리 상태다. `.`은 변경 없음이다.

| 조건 | 분류 | 표시 상태 |
|---|---|---|
| `1`/`2` 레코드이고 `X != '.'` | **Staged** | `X` (M, T, A, D, R, C) |
| `1`/`2` 레코드이고 `Y != '.'` | **Unstaged** | `Y` (M, T, D) |
| `u` 레코드 | **Conflicted** | `XY` ∈ {`DD`, `AU`, `UD`, `UA`, `DU`, `AA`, `UU`} |
| `?` 레코드 | **Untracked** | `?` |

- `MM`처럼 X와 Y가 모두 있으면 Staged와 Unstaged **양쪽에** 나온다.
- 이름 변경(`R`)은 Staged 목록에서 `orig → new`로 표시한다.

| 테스트 | 사례 |
|---|---|
| PAR-STATUS-01 | 일반 브랜치 + upstream + ab |
| PAR-STATUS-02 | `(initial)` unborn |
| PAR-STATUS-03 | `(detached)` |
| PAR-STATUS-04 | upstream 사라짐 (`branch.ab` 없음) |
| PAR-STATUS-05 | upstream 없음 |
| PAR-STATUS-06 | `# stash N` |
| PAR-STATUS-07 | `MM` → 양쪽 목록 |
| PAR-STATUS-08 | `2` 레코드 경로 순서 |
| PAR-STATUS-09 | `u` 레코드 7가지 XY |
| PAR-STATUS-10 | 공백·개행·NFD·`-` 시작 파일명·`--` 파일명·`:(exclude)` 파일명 |
| PAR-STATUS-11 | 서브모듈 `S.M.`, `SC..` |
| PAR-STATUS-12 | 타입 변경 `T` |
| PAR-STATUS-13 | 올바르지 않은 UTF-8 경로 → `isRepresentable = false` |
| PAR-STATUS-14 | 잘린 출력 |
| PAR-STATUS-15 | 알 수 없는 헤더 무시, 알 수 없는 레코드 skip 카운트 |

---

## 4. StashParser — `log -g -z --ignore-missing --format=%gd%x00%H%x00%gs%x00%ct%x00%P refs/stash --`

출력은 `stash list -z --format=…`와 같다. `stash list`는 bare 저장소에서 `this operation must be run in a work tree`로 실패하므로 같은 reflog 조회를 `log -g`로 직접 실행한다(#222).

**형식.** 레코드마다 필드 5개다. 필드와 레코드 끝 모두 NUL이므로, 토큰을 5개씩 묶는다.

```
stash@{0}␀9db73c1d…␀On feat/x: exp: try␀1793853652␀0f047e0d… 64575abd… 8e49d42e…␀stash@{1}␀7130d8ef…␀WIP on main: 0f047e0 base2␀1793853652␀0f047e0d… 524b29ec…␀
```

- `%gd`: `stash@{n}`. 표시와 정렬용이다. git 인자로는 `%H`(OID)를 쓴다. `stash@{n}`은 stash가 바뀌면 다른 항목을 가리키기 때문이다.
- `%gs`: reflog 제목. `^(WIP on|On) (.+?): (.*)$`로 브랜치와 메시지를 뽑는다 (실패하면 원문 그대로 표시).
- `%ct`: epoch 초. 상대 시간(`%cr`)은 쓰지 않고 앱에서 형식을 만든다.
- `%P`: 부모 OID를 공백 하나로 나눈다. 진짜 stash는 2–3개(기준 커밋, index 커밋, `-u`/`-a`면 untracked 커밋). S-04의 `Base commit`과 `Includes`가 이것을 쓴다(#71). stash 커밋이 아닌 항목(손으로 `refs/stash`에 쓴 루트 커밋, 부모 넷 이상)은 부모를 `[]`로 두어 목록과 저장소 개요가 계속 뜨게 한다. OID 형식이 아니면(git으로 되돌아가는 값이므로) 실패.
- 토큰 수가 5의 배수가 아니면 `parseFailed`다 (잘린 출력이면 마지막 묶음만 버림).

| 테스트 | 사례 |
|---|---|
| PAR-STASH-01 | `WIP on` / `On` 제목 |
| PAR-STASH-02 | 제목에 콜론, 유니코드 |
| PAR-STASH-03 | 빈 목록 |
| PAR-STASH-04 | 필드 수 불일치, 잘못된 부모 목록 → 실패 |

---

## 5. LogParser

### 5.1 그래프·파일 이력 — `%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%(trailers:key=Co-authored-by,valueonly,unfold,separator=%x1f)` + `-z`

레코드마다 필드 7개, 토큰을 7개씩 묶는다.

```
2f833676…␀837976f6… eecf7339…␀t␀t@example.com␀1793853652␀Merge branch 'other'␀␀
306f57fa…␀␀t␀t@example.com␀1793853652␀human and AI␀Claude Opus 5.5 <noreply@anthropic.com>␟Alice <alice@example.com>␀
```

| 필드 | 규칙 |
|---|---|
| `%H` | OID 검증. 실패하면 `parseFailed` (재동기화 시도 없음) |
| `%P` | 공백으로 나눈 OID 목록. 루트 커밋은 빈 문자열, 병합은 2개, octopus는 3개 이상 |
| `%an`, `%ae` | 표시용 문자열 |
| `%at` | epoch 초 |
| `%s` | 제목. 커밋 메시지에 NUL이 있으면 git이 NUL 앞에서 자른다 (`hash-object --literally`로 만든 객체로 확인). 단, 저장소 로컬 `i18n.logOutputEncoding`·`i18n.commitEncoding`이 출력 전체를 다시 인코딩하면 메시지 텍스트가 NUL로 바뀌어 필드가 밀릴 수 있다. 공통 인자로 출력 인코딩을 고정해 막는다 (#205) |
| `%(trailers:…)` | `Co-authored-by` 트레일러 값. 키는 대소문자를 가리지 않고, 여러 줄로 접힌 값은 `unfold`로 한 줄이 된다. 값 사이는 U+001F(`␟`), 없으면 빈 필드. 본문 중간의 `Co-authored-by:` 줄은 트레일러가 아니다. 표시용이라 손실 디코딩하고 빈 값은 버린다 → `CommitNode.coAuthors`. AI 배지는 `AIAgentRule`(알려진 에이전트 이메일·GitHub bot 접미사, 설정으로 확장)로 판정한다. 저장소 로컬 `trailer.<key>.cmd`/`.command`는 pretty 형식에서 실행되지 않는다 (E39, SEC-T4-06). 표시 범위 한계: 로컬 `trailer.<x>.key=Co-authored-by`(git은 키를 접두사로 맞춤), `trailer.separators`, `core.commentChar`/`commentString`으로 어떤 줄이 co-author인지 바뀔 수 있다. 값 안의 U+001F는 co-author를 하나 더 만든다. 모두 표시에만 영향을 주고 아무것도 실행되지 않는다. 화면은 값의 제어·bidi 문자를 제목·이름과 같은 방식으로 처리한다 |

- `--graph`는 쓰지 않는다. 레인은 GraphEngine이 `%P`로 계산한다 (ADR-0010).
- ref 범위는 `--branches --remotes --tags --exclude=refs/* --all`이다. 브랜치·원격 추적 ref·태그와 모든 워크트리의 HEAD만 따라간다(`--all`은 `refs/*`를 빼면 HEAD만 더한다). stash, notes, `refs/prefetch`(`git maintenance`), `refs/original`(filter-branch), `refs/pull` 같은 다른 이름공간의 커밋은 그래프에 나오지 않는다 (#308, git 2.54로 확인).
- 서명 관련 포맷(`%G?`, `%GS`, `%GK`, `%GF`, `%GP`, `%GT`)은 금지한다. 쓰면 `gpg.program`이 실행된다 (T7, 확인).

### 5.3 파일 이력 — 5.1의 형식 + `--numstat` (+ `--follow`)

레코드의 필드 7개 뒤에, 그 커밋이 파일을 바꿨으면 `\n`과 numstat 항목 하나가 온다. 병합처럼 stat이 없는 레코드는 다음 레코드가 바로 이어진다(`--follow`에서는 병합이 나오지 않는 것을 확인).

```
71d743de…␀884ed6dd…␀t␀t@example.com␀1793853652␀chore: make it binary␀␀⏎-⇥-⇥Status.swift␀
4a8b5413…␀356e2f29…␀t␀t@example.com␀1793853652␀refactor: rename to Status.swift␀␀⏎1⇥0⇥␀Parser.swift␀Status.swift␀
```

| 부분 | 규칙 |
|---|---|
| `added⇥deleted⇥path` | 개수는 ASCII 숫자(18자리 이하), `-`면 바이너리(`nil`). 경로는 원시 바이트(`GitPath`) |
| `added⇥deleted⇥` + `old␀new␀` | rename. 그 커밋의 경로는 `new`, `renamed from`은 `old` |
| stat 없음 | 개수는 모름(`hasStat == false`). 경로는 따라가던 경로를 유지한다 |

- 레코드마다 경로를 기록하고, 더 오래된 커밋은 rename 이전 경로를 이어받는다. 페이지는 늘 가장 새 커밋부터 다시 읽으므로(카탈로그 `fileHistory`) 경로를 페이지 사이에 넘기지 않는다.
- 잘린 출력은 마지막 레코드를 버린다(stat이 잘렸을 수 있음). 잘리지 않은 출력은 NUL로 끝나야 하고, 잘못된 개수·빈 rename 경로는 실패한다.

### 5.2 커밋 상세 — `%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%ce%x00%ct%x00%B` + `-z -1`

필드 9개이고, 마지막 `%B`(전체 메시지)는 여러 줄일 수 있다. 메시지 끝의 개행은 보존하되 표시할 때 다듬는다.

| 테스트 | 사례 |
|---|---|
| PAR-LOG-01 | 루트 커밋 (빈 `%P`) |
| PAR-LOG-02 | 병합(부모 2개), octopus(3개 이상) |
| PAR-LOG-03 | 유니코드·이모지·빈 제목 |
| PAR-LOG-04 | SHA-256 저장소 (64자리 OID) |
| PAR-LOG-05 | `%B` 여러 줄, 끝 개행 |
| PAR-LOG-06 | 잘못된 OID → 실패 |
| PAR-LOG-07 | 잘린 마지막 레코드 버림 |
| PAR-LOG-08 | NUL이 들어간 커밋 메시지 (literally 객체) |
| PAR-LOG-09 | co-author 트레일러: 없음, 여러 개(대소문자 섞임), 사람+AI, 접힌 값, 본문 중간 줄 |
| PAR-LOG-10 | 파일 이력(§5.3): numstat, rename(이전·새 경로), 바이너리, 커밋마다의 경로 |
| PAR-LOG-11 | 파일 이력의 잘린 출력과 잘못된 numstat |
| PAR-LOG-12 | 파일 이력에서 제목 안의 여분 NUL → 실패(재동기화하지 않음) |
| PAR-LOG-13 | 스트리밍 그래프(`GraphStreamParser`, #254): 어떤 크기로 잘라 넣어도 전체 출력의 `parseGraph`와 같음, 레코드의 마지막 NUL이 오는 즉시 그 커밋을 냄, 레코드 안에서 끝나면 잘림이 아닐 때 실패, 잘못된 레코드는 전체 스트림 기준 오프셋으로 실패 |

---

## 6. RefParser — `for-each-ref --format=%(refname)%00%(objectname)%00%(*objectname)%00%(upstream)%00%(HEAD)%00%(creatordate:unix)%00%(symref)%00%(upstream:track,nobracket)%00%(upstream:remotename)%00%(upstream:remoteref)`

**형식.** 레코드는 LF로 끝나고, 필드 10개는 NUL로 나눈다. refname에는 제어 문자가 들어갈 수 없으므로(`check-ref-format` 규칙) LF 구분이 안전하다. 예시는 Apple Git 2.54.0, `LC_ALL=C` 출력이다.

```
refs/heads/both␀2880404c…␀␀refs/remotes/origin/both␀ ␀1793853652␀␀ahead 1, behind 2␀origin␀refs/heads/both
refs/heads/main␀9692941d…␀␀refs/remotes/origin/main␀*␀1793853652␀␀␀origin␀refs/heads/main
refs/remotes/origin/HEAD␀9692941d…␀␀␀ ␀1793853652␀refs/remotes/origin/main␀␀␀
refs/tags/v1␀4fa02a16…␀9692941d…␀␀ ␀␀␀␀␀
```

| 필드 | 규칙 |
|---|---|
| `%(refname)` | `refs/heads/`, `refs/remotes/`, `refs/tags/`로 분류. 그 밖의 접두사는 무시 |
| `%(objectname)` | OID. 주석 태그는 태그 객체 OID |
| `%(*objectname)` | 주석 태그가 가리키는 커밋 OID. 경량 태그·브랜치는 빈 값 (확인) |
| `%(upstream)` | 전체 ref 이름 또는 빈 값 |
| `%(HEAD)` | `*`(메인 워크트리가 체크아웃한 브랜치) 또는 공백 |
| `%(creatordate:unix)` | epoch 초. 커밋(브랜치, 가벼운 태그)은 committer 날짜, 주석 태그는 tagger 날짜다. `committerdate`는 주석 태그에서 비어 있어 TAGS 정렬에 쓸 수 없었다(#377). 그래도 비어 있을 수 있다(tagger 없는 태그 객체) |
| `%(symref)` | `refs/remotes/origin/HEAD` 같은 심볼릭 ref의 대상 |
| `%(upstream:track,nobracket)` | 빈 값, `ahead N`, `behind M`, `ahead N, behind M`, `gone` 다섯 가지(#54, Apple Git 2.54.0 확인). 빈 값은 `%(upstream)`이 있으면 "같음", 없으면 "upstream 없음"이다. upstream 없이 값이 있으면 형식 위반이다 |
| `%(upstream:remotename)` | `branch.<n>.remote`. 원격 이름 전체(`/`가 들어갈 수 있다), 로컬 upstream은 `.`, 없으면 빈 값(#115, Apple Git 2.54.0·git 2.36.6 확인). 로컬 브랜치에서만 읽는다 |
| `%(upstream:remoteref)` | `branch.<n>.merge`. 그 원격의 전체 ref 이름(`refs/heads/feature`) 또는 빈 값. 로컬 브랜치에서만 읽는다 |

- refname, `%(upstream)`, `%(symref)`는 git 인자로 되돌아갈 수 있으므로 손실 디코딩하지 않는다. git은 이런 이름을 허용하므로 형식 위반이 아니라 내용 문제로 다룬다. refname이나 `%(upstream)`이 올바른 UTF-8이 아니거나 `FullRefName` 검증(`-`로 시작하는 구성 요소, `..`, `.lock` 등)을 통과하지 못하면 그 레코드만 건너뛰고 `skippedRecords`를 올린다(UI는 비차단 경고). upstream이 있는 브랜치를 "upstream 없음"으로 보이지 않기 위해서다. `%(symref)`가 그렇다면 `symbolicTarget`만 비운다. 다른 필드의 형식 위반은 이 레코드에서도 전체 실패다.
- `%(upstream:remotename)`·`%(upstream:remoteref)`는 PR head 저장소·브랜치와 맞춰 보는 데만 쓰고 git 인자로 되돌리지 않는다(ADR-0023 §4). 올바른 UTF-8이 아니면 그 값만 비우고 레코드는 남긴다.
- `%(HEAD)`는 `*` 또는 공백 한 글자, 날짜는 부호 없는 10진수 또는 빈 값, 카운트는 부호 없는 10진수만 허용한다.
- 원격 이름은 `refs/remotes/` 뒤 첫 구성 요소로 정한다. 원격 이름에 `/`가 들어간 경우는 `configList`의 원격 목록과 맞춰 보정한다.
- 잘린 출력은 LF로 끝나지 않은 마지막 레코드만 버리고 `isPartial`을 표시한다.
- 결과 모델: `Branch.upstreamStatus`(`UpstreamStatus`)가 ahead/behind를 담는다. upstream 이름은 전체 ref 이름이다. 사이드바 LOCAL의 `↑n ↓n`은 이 값을 쓰고, 브랜치마다 `rev-list`를 실행하지 않는다(#167 S5).

연결 워크트리에서 체크아웃한 브랜치는 `WorktreeParser` 결과의 `branch`와 맞춰 표시한다.

| 테스트 | 사례 |
|---|---|
| PAR-REF-01 | heads/remotes/tags, HEAD 표시 |
| PAR-REF-02 | 주석 태그 peel |
| PAR-REF-03 | `origin/HEAD` symref |
| PAR-REF-04 | 슬래시·유니코드 브랜치명 |
| PAR-REF-05 | upstream 없음 |
| PAR-REF-06 | `%(upstream:track,nobracket)` 다섯 경우, 형식 위반 → 실패 |
| PAR-REF-07 | `%(upstream:remotename)`·`%(upstream:remoteref)`: `/`가 든 원격 이름, 로컬 upstream `.`, upstream 없음, 원격 추적 ref는 무시, UTF-8 아님 → 그 값만 비움 |

---

## 7. RevListParser — `rev-list --left-right --count A...B`

출력은 `<left>\t<right>\n` 한 줄이다. `<upstream>...<local>` 순서로 부르므로 left가 behind, right가 ahead다 (확인: `0\t1` ↔ `branch.ab +1 -0`).

한 줄이 아니거나, 탭이 없거나, 부호 없는 10진수가 아니면 실패한다. 출력이 몇 바이트뿐이라 잘린 결과는 믿을 수 없으므로 잘림도 실패로 다룬다. 사이드바 LOCAL은 §6의 track 필드를 쓰므로, 이 파서는 upstream이 아닌 기준 브랜치와의 ahead/behind(비교 카드, S-11, #157)에 쓴다.

| 테스트 | 사례 |
|---|---|
| PAR-REVLIST-01 | 정상 |
| PAR-REVLIST-02 | 형식 위반 → 실패 |

---

## 8. NumstatParser

### 8.1 커밋 파일 — `diff-tree -r -z --raw --numstat -M ...`

raw 레코드가 모두 나온 뒤 numstat 레코드가 나온다 (확인).

```
:100644 100644 8792505e… 8792505e… R100␀a.txt␀b.txt␀0	0	␀a.txt␀b.txt␀
```

| 종류 | 형식 |
|---|---|
| raw | `:<srcmode> <dstmode> <srcoid> <dstoid> <status>[score]␀<path>␀` + 이름 변경·복사(`R`, `C`)면 `<new path>␀` |
| numstat | `<added>\t<deleted>\t<path>␀` |
| numstat (이름 변경) | `<added>\t<deleted>\t␀<old>␀<new>␀` (세 번째 필드가 빈 값) |
| numstat (바이너리) | `-\t-\t<path>␀` → `isBinary = true` |

- raw 구간은 토큰이 `:`로 시작하는 동안 이어진다.
- 두 구간은 새 경로 기준으로 합친다. 상태 문자(A, M, D, R, C, T)는 raw에서, 줄 수는 numstat에서 가져온다.
  - numstat 레코드는 raw 레코드와 같은 순서로 하나씩 나온다. 타입 변경(`T`)도 numstat 레코드는 하나다 (확인). 순서·개수·경로가 어긋나면 `parseFailed`.
  - 잘린 출력에서 numstat이 잘려 나간 파일은 버린다. 줄 수를 모르는데 `nil`로 두면 바이너리로 보이기 때문이다.
- 루트 커밋은 `--root`가 있어야 파일 목록이 나온다 (확인).
- 병합 커밋은 첫 부모를 명시해 두 트리를 비교한다. 기본 동작은 파일 목록을 내지 않는다 (확인).
- 기준 브랜치 비교(`compareFiles`, #157)의 `git diff --merge-base -z --raw --numstat -M --no-abbrev`도 같은 형식이라 `parseCommitFiles`를 그대로 쓴다.
  - `git diff --raw`는 객체 이름을 7자로 줄여 쓴다. 파서는 40·64자만 받으므로 명령에 `--no-abbrev`가 꼭 있어야 한다 (확인).
  - 작업 트리를 포함하면 작업 트리 쪽 객체 이름이 0으로 채워진다(`0000…`, 수정·추가 파일). 객체 이름은 형식만 검사하고 모델에 담지 않으므로 그대로 받는다 (Apple Git 2.50.1 확인).
  - **작업 트리 쪽 레코드는 numstat 없이 나올 수 있다(#305, PAR-NUMSTAT-07).** 앱은 index를 쓰지 않는다(`diff.autoRefreshIndex=false`). 그래서 내용은 같고 mtime만 바뀐 파일이 index보다 오래되었으면(racily clean이 아니면) git이 해시하지 않고 raw에 넣는다(작업 트리 쪽 `0000…`, `M`). 그다음 diff 단계에서 바뀐 것이 없다고 보고 numstat은 내지 않는다(Apple Git 2.50.1 확인).
    - 파서는 numstat과 짝이 맞지 않는 raw 레코드 가운데 **목적지 객체 이름이 0인 것만** 건너뛰고 결과에서 뺀다. 내용이 바뀌지 않았으므로 변경이 아니다.
    - 커밋의 레코드(`diff-tree`, 객체 이름이 실제 값)는 지금처럼 numstat이 꼭 있어야 하고, 어긋나면 `parseFailed`다.

### 8.2 stash 파일 — `stash show --include-untracked --numstat -z`

numstat 레코드만 나온다. `--include-untracked`가 있으면 untracked 부분 파일도 포함된다 (git 2.32+, 확인). untracked 출신 파일인지는 stash 커밋의 세 번째 부모(`%P`)에 있는지로 구분한다. 세 번째 부모는 untracked 트리만 담은 루트 커밋이라서 `commitFiles(<stash>^3)`의 파일 목록이 곧 untracked 파일 목록이다. 이 경로 집합을 `parseStashFiles(untrackedPaths:)`에 넘기고 raw 바이트로 비교한다 (PAR-NUMSTAT-05, Apple Git 2.50.1 확인).

- stash 출력에도 이름 변경 numstat(`<added>\t<deleted>\t␀<old>␀<new>␀`)이 나온다. `stash show`는 `diff.renames` 기본값(켜짐)을 따른다 (확인).


- untracked 출신 판별은 세 번째 부모(`<stash>^3`)의 `commitFiles`(`--root`)로 한다. 조작된 stash에서 `^3`이 루트 커밋이 아니면 그 부모와의 diff가 나오지만, 보이는 패치가 달라질 뿐 읽기 전용 `diff-tree`라 보안 영향은 없다(#71 리뷰).
### 8.3 워크트리 줄 수 — `diff [--cached] --numstat -z -M` (#230)

numstat 레코드만 나온다. 형식은 §8.2와 같다(`status`는 `nil`). `parseWorktreeFiles(_:excluding:truncated:)`가 읽는다.

- 충돌 중인 경로는 unstaged 출력에 레코드가 두 개 나온다(확인, [git-command-catalog.md §3](git-command-catalog.md)). 호출자는 status의 conflicted 경로를 `excluding`으로 넘기고, 파서는 그 레코드를 버린다. 나머지 경로가 두 번 나오면 파싱 실패다.
- 잘린 출력에서는 잘린 마지막 레코드만 버린다. 줄 수를 모르는 파일은 결과에 없으므로 화면에서 줄 수 없이 보인다(`isPartial`).
- 바이너리(`-\t-`)는 `added`·`deleted`가 `nil`이다. 화면은 `binary`로 쓴다.

| 테스트 | 사례 |
|---|---|
| PAR-NUMSTAT-01 | 추가·수정·삭제 |
| PAR-NUMSTAT-02 | 이름 변경 (빈 경로 필드) |
| PAR-NUMSTAT-03 | 바이너리 `-` |
| PAR-NUMSTAT-04 | raw + numstat 합치기, 상태 문자 |
| PAR-NUMSTAT-05 | stash untracked 부분 |
| PAR-NUMSTAT-06 | 워크트리 줄 수: 충돌 경로 제외, 그 밖의 중복 거부, 잘림 |
| PAR-NUMSTAT-07 | 작업 트리 쪽(목적지 `0000…`) raw 레코드는 numstat 없이 나오면 버림. 커밋 레코드는 여전히 짝 필수 (#305) |

---

## 9. ConfigParser — `config --list --show-scope -z --includes`

**형식.** 항목마다 `scope␀` 다음에 `key LF value␀`가 온다. 값이 없는 불리언 키는 LF 없이 `key␀`다 (확인).

```
unknown␀credential.helper\nosxkeychain␀global␀user.name\nt␀local␀x.v\na\nb␀local␀x.flag␀
```

- **scope**: `system`, `global`, `local`, `worktree`, `command`, `unknown`(Apple Git 내장 설정 파일, 확인). include로 불러온 항목은 포함한 쪽의 scope로 보고된다 (확인).
- **키와 값 분리**: 키는 첫 LF 전까지다. 값에는 LF가 들어갈 수 있다 (`"a\nb"` → 값 `a␊b`, 확인).
- **키 분해**: 첫 `.` 앞이 section, 마지막 `.` 뒤가 variable, 그 사이가 subsection이다. subsection에는 `.`이 들어갈 수 있다. 예: `credential.https://example.com.helper`, `url.ext::sh -c x.insteadof`. section과 variable은 소문자로 정규화되어 나오고, subsection은 대소문자를 보존한다.
- 결과는 `[ConfigEntry(scope, section, subsection?, variable, value?)]`이며, **원래 순서를 보존**한다. credential helper를 재삽입할 때 순서가 필요하다 (ADR-0009).

| 테스트 | 사례 |
|---|---|
| PAR-CONFIG-01 | 모든 scope 종류, `unknown` 포함 |
| PAR-CONFIG-02 | `.`이 든 subsection (URL, insteadOf 대상) |
| PAR-CONFIG-03 | LF가 든 값 |
| PAR-CONFIG-04 | 값 없는 불리언 키 |
| PAR-CONFIG-05 | 필터 드라이버 이름 검증 (허용 문자 밖이면 fail closed) |
| PAR-CONFIG-06 | 순서 보존 (빈 값 초기화 항목 포함) |

---

## 10. gh JSON

`JSONDecoder`로 디코딩한다. 모르는 필드는 무시하고, 필수 필드가 없으면 `parseFailed`다.

### 10.1 GHAuthParser — `gh auth status --json hosts`

```json
{"hosts":{"github.com":[{"active":true,"gitProtocol":"https","host":"github.com","login":"<login>","scopes":"...","state":"success","tokenSource":"keyring"}]}}
```

- 로그인 판정: `hosts["github.com"]`에 `active == true && state == "success"`인 항목이 있다.
- 로그인 호스트(ADR-0025 §1): 계정이 하나 이상 있는 `hosts`의 키를 `RemoteHost`로 검증해 소문자로 모은다. 통과하지 못한 키는 버린다. github.com 로그인이 없어도 다른 호스트는 모은다.
- 활성 계정(ADR-0025 §4, 표시용): 호스트마다 `active == true && state == "success"`인 항목의 login이 GitHub login 규칙(1–39자 영숫자·`-`)을 통과하면 `GHAccount`로 남기고, 그 호스트의 나머지 계정 수를 함께 센다. 규칙을 통과하지 못한 login은 그 계정만 숨기고 보고 전체를 실패로 보지 않는다(github.com의 상태 판정은 그대로 실패).
- 종료 코드는 판단에 쓰지 않는다. `--json`이면 인증 문제가 있어도 0이다.
- `scopes`와 `tokenSource`는 표시하지 않는다. 그 밖의 필드도 판단에 필요한 것만 쓴다.

### 10.2 IssueParser — `gh issue list --json number,title,state,labels,assignees,updatedAt,url`

| 필드 | 타입 | 필수 |
|---|---|---|
| `number` | Int | 예 |
| `title` | String | 예 |
| `state` | String (`OPEN`, `CLOSED`) | 예 |
| `labels` | `[{name, color}]` | 아니오 (없으면 빈 배열) |
| `assignees` | `[{login}]` | 아니오 |
| `updatedAt` | ISO 8601 | 예 |
| `url` | URL (`https://<조회한 저장소의 HOST>/`로 시작해야 함, ADR-0025 §5) | 예 |

| 테스트 | 사례 |
|---|---|
| PAR-GH-01 | 로그인 상태 |
| PAR-GH-02 | 미로그인, state 실패, 빈 hosts |
| PAR-GH-03 | 이슈 목록 (라벨, 담당자, 선택 필드 누락) |
| PAR-GH-04 | 예상 밖 JSON → 실패 |
| PAR-GH-07 | 호스트별 활성 계정과 나머지 계정 수, 이상한 login·실패 상태 계정은 그 계정만 숨김 (ADR-0025 §4) |

### 10.3 PullRequestParser — `gh pr list --json number,title,state,isDraft,isCrossRepository,headRefName,headRepositoryOwner,headRepository,baseRefName,reviewDecision,mergedAt,updatedAt,url`

ADR-0023 §3. 공개 저장소에는 누구나 PR을 열 수 있으므로 항목 하나가 이상해도 나머지를 숨기지 않는다. 목록 전체가 실패하는 것은 최상위가 JSON 배열이 아닐 때뿐이다.

```json
[{"baseRefName":"main","headRefName":"feat/42-x","headRepository":{"id":"R_…","name":"app","nameWithOwner":"team/app"},"headRepositoryOwner":{"id":"U_…","login":"team","name":"…"},"isCrossRepository":false,"isDraft":false,"mergedAt":null,"number":57,"reviewDecision":"","state":"OPEN","title":"…","updatedAt":"2026-11-08T03:14:08Z","url":"https://github.com/team/app/pull/57"}]
```

| 필드 | 규칙 |
|---|---|
| `number` | 양의 Int. 없거나 형식이 다르면 그 항목만 버린다 |
| `state` | `OPEN`, `CLOSED`, `MERGED`. 모르는 값은 `unknown`. 없으면 그 항목만 버린다 |
| `url` | `https://<조회한 저장소의 HOST>/`로 시작해야 한다. 아니면 그 항목만 버린다. 여는 것은 조회한 저장소의 `/pull/<그 번호>`일 때뿐이다(표시 규칙) |
| `headRepositoryOwner.login`, `headRepository.name`, `headRefName` | 셋 중 하나라도 없거나 null·빈 값이면 `head == nil`. 항목은 남고 어떤 브랜치에도 잇지 않는다(fork를 지운 PR) |
| `reviewDecision` | `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`. 빈 문자열(gh 2.95.0의 "결정 없음")과 모르는 값은 없음 |
| `title`, `baseRefName`, `isDraft`, `updatedAt` | 없거나 형식이 다르면 빈 값, `false`, `nil` |
| `isCrossRepository`, `mergedAt` | 읽지 않는다(잇기는 head 저장소로 판단) |

- 제목·브랜치 이름은 원문 그대로 두고 표시할 때 이스케이프한다.
- gh 2.95.0의 기본 정렬은 만든 시각 내림차순이다(확인).

| 테스트 | 사례 |
|---|---|
| PAR-GH-05 | PR 목록(상태 셋, 리뷰 결정 셋, 소수 초, 초안), 모르는 값은 `unknown`·없음 |
| PAR-GH-06 | 배열 아닌 출력·깨진 JSON·잘린 배열 → 실패 |

---

## 11. 기타 파서

### 11.1 VersionParser — `git version`

`^git version (\d+)\.(\d+)(?:\.(\d+))?` 를 읽는다. 예: `git version 2.50.1 (Apple Git-155)` → 2.50.1. 2.36 미만이면 `unsupportedVersion`이다.

| 테스트 | 사례 |
|---|---|
| PAR-VER-01 | Apple Git, Homebrew git, `-rc` 버전 |
| PAR-VER-02 | 최소 버전 미만 |

### 11.2 Probe — `rev-parse --path-format=absolute --show-toplevel --git-common-dir --is-bare-repository`

출력은 줄 3개다. 경로에 제어 문자(LF 포함)가 있으면 등록을 거부한다 (`PathValidator`).

`ProbeParser`(#84) 규칙:
- 정확히 LF로 끝나는 줄 3개만 받는다. 유효한 UTF-8이 아니거나, 줄 수가 다르거나, 마지막 LF가 없으면 실패한다. 경로 안의 LF는 필드를 밀어내므로 추측하지 않는다.
- 1·2번째 줄은 `/`로 시작하는 절대 경로이고 제어 문자(C0, DEL, C1)가 없어야 한다. git이 출력한 그대로 쓴다(`standardizedFileURL`은 `/private`를 떼어 `realpath(3)` 결과와 어긋난다).
- 3번째 줄은 `true` 또는 `false`.
- 맨 저장소와 `.git` 안에서는 `--show-toplevel`이 `fatal: this operation must be run in a work tree`(종료 128)로 실패한다. 등록은 이를 "워크트리를 추가하라"는 안내로 거부한다.
- 메인 워크트리는 공통 디렉터리 이름이 `.git`이면 그 부모, 아니면(`--separate-git-dir`) probe한 워크트리로 본다.

| 테스트 | 사례 |
|---|---|
| `ProbeParserTests` | 3줄, 연결 워크트리, 공백·유니코드, 줄 수 오류, 경로 안 LF, 상대 경로, 잘못된 bare 값, 마지막 LF 없음, 제어 문자, 잘못된 UTF-8 |

#### 11.2.1 Git 디렉터리 probe (#222) — `rev-parse --path-format=absolute --git-common-dir --absolute-git-dir --is-bare-repository --is-inside-work-tree`

등록은 이 probe를 먼저 실행한다. `--show-toplevel`이 없으므로 bare 저장소, 그 관리 디렉터리(`worktrees/<id>`), `.git` 안에서도 종료 0이다. 워크트리 안일 때만 위 `probeRepository`를 이어서 실행한다.

`GitDirectoryProbeParser` 규칙:
- 정확히 LF로 끝나는 줄 4개만 받는다. 1·2번째 줄(공통 git 디렉터리, 이 위치의 git 디렉터리)은 `ProbeParser`와 같은 경로 규칙을 따른다. 3·4번째 줄은 `true` 또는 `false`다.

실측 (Apple Git 2.50.1, git 2.54.0):

| 위치 | 공통 디렉터리 | git 디렉터리 | bare | 워크트리 안 |
|---|---|---|---|---|
| bare 저장소 `repo.git` | `repo.git` | `repo.git` | true | false |
| bare 안 하위 폴더 `repo.git/refs` | `repo.git` | `repo.git` | true | false |
| bare의 관리 디렉터리 `repo.git/worktrees/a` | `repo.git` | `repo.git/worktrees/a` | true | false |
| bare의 연결 워크트리 `a` | `repo.git` | `repo.git/worktrees/a` | **false** | true |
| 일반 저장소 | `x/.git` | `x/.git` | false | true |
| 일반 저장소의 `.git` | `x/.git` | `x/.git` | false | false |

- bare 저장소의 연결 워크트리는 bare가 `false`다. 그래서 공통 git 디렉터리에서 이 probe를 한 번 더 실행해 bare 저장소인지 확인한다.

| 테스트 | 사례 |
|---|---|
| `GitDirectoryProbeParserTests` | 4줄, bare, 워크트리, 줄 수 오류, 경로 안 LF, 상대 경로, 잘못된 불리언, 마지막 LF 없음, 잘못된 UTF-8 |

### 11.3 IssueRefExtractor (G8)

| 출처 | 규칙 |
|---|---|
| 브랜치명 | `^(?:feat\|fix\|docs\|test\|chore\|spike\|refactor\|perf\|ci)/(\d{1,7})-` 우선, 다음으로 `(?:^\|/)(\d{1,7})-` |
| 커밋 제목 | `#(\d{1,7})\b`. `owner/repo#n` 형태는 같은 저장소일 때만 매칭 |
| 커밋 트레일러 | `^Refs: #(\d{1,7})$`, `^(?:Closes\|Fixes\|Resolves) #(\d{1,7})` (`%B`에서) |

매칭된 번호는 이슈 목록에 있을 때만 링크로 표시한다. 목록에 없으면 회색 `#n`으로 표시한다.

경계 규칙 (오탐 배제, #57에서 확정):
- 숫자는 ASCII `0-9`만 센다. `\d`가 받아들이는 전각·기타 유니코드 숫자는 제외한다.
- 숫자가 8자리 이상 이어지면 앞 7자리로 자르지 않고 매칭하지 않는다. `0`은 이슈 번호가 아니다.
- 제목의 `#`는 단어 문자, `&`, `/`, `#` 바로 뒤에 오면 매칭하지 않는다. 그래서 `C#10`, `&#123;`, `issue#12`, `path/#12`가 빠진다. `#define`은 숫자가 없어서 빠진다.
- `owner/repo#n`은 `owner/repo`가 현재 저장소와 같을 때만 매칭한다(GitHub처럼 대소문자 무시). `evil-owner/repo#n`이나 `x/owner/repo#n`은 다른 대상으로 보고 매칭하지 않는다.
- 트레일러는 줄 단위로 보고, `\r\n` 줄바꿈도 받아들인다.

| 테스트 | 사례 |
|---|---|
| PAR-ISSUE-01 | 브랜치 규칙 매칭 |
| PAR-ISSUE-02 | 제목의 `#n`, 오탐(`C#`, `#define`) 배제 |
| PAR-ISSUE-03 | 트레일러 |

### 11.4 FetchProgressParser — `fetch --progress` stderr (#76)

git이 실행되는 동안 stderr 조각을 순서대로 받아 `FetchProgress`(단계, 완료 수, 전체 수, 완료 여부)를 만든다. 형식은 Apple Git 2.54.0에서 채집했다.

```
remote: Enumerating objects: 304, done.        ⏎
remote: Counting objects:  50% (152/304)        ␍
Receiving objects: 100% (202/202), 304.96 KiB | 76.24 MiB/s, done.⏎
Resolving deltas: 100% (102/102), completed with 102 local objects.⏎
```

- `\r`와 `\n` 모두 줄 끝이다. git은 같은 줄을 `\r`로 다시 쓰고, 단계가 끝나면 `\n`을 쓴다.
- `remote: ` 접두사와 줄 끝의 공백 채움을 떼고, 다음 다섯 단계만 읽는다: `Enumerating objects`(개수만), `Counting objects`, `Compressing objects`, `Receiving objects`, `Resolving deltas`.
- 비율 형식은 `<p>% (<n>/<total>)`이다. `p ≤ 100`, `n ≤ total`, ASCII 숫자 15자리 이하만 받는다. `)` 뒤에는 아무것도 없거나 `, `로 시작하는 꼬리(처리량, `done.`)만 올 수 있다. 완료는 `, done.`으로 끝나거나 `, completed with `로 시작하는 꼬리로 판단한다.
- 그 밖의 줄(`From …`, ref 갱신 줄, `remote: Total …`, 알 수 없는 단계)과 형식이 어긋난 줄은 조용히 무시한다. 진행률은 표시용이고, `remote:` 줄은 서버가 쓰기 때문이다. 문자열은 결과에 담지 않는다.
- 줄 길이 상한은 1024바이트다. 넘으면 그 줄의 나머지를 버리고 다음 줄부터 다시 읽는다.
- 직전과 같은 갱신(처리량만 바뀐 경우)은 다시 내보내지 않는다.
- 어떤 단계가 나오는지는 팩 크기와 속도에 따라 다르다. 작은 팩은 `Receiving objects`를 건너뛰기도 한다.

| 테스트 | 사례 |
|---|---|
| PAR-FETCH-01 | 실제 출력의 모든 단계가 순서대로 나옴 (중간에 끼어든 `remote: Total` 포함) |
| PAR-FETCH-02 | 바이트 단위로 나눠 넣어도 결과가 같음 |
| PAR-FETCH-03 | 진행률이 아닌 줄 무시 |
| PAR-FETCH-04 | 형식이 어긋난 숫자(100% 초과, `n > total`, 음수, 전각 숫자, 오버플로, 뒤에 붙은 제어 문자) 무시 |
| PAR-FETCH-05 | 상한을 넘는 줄을 버린 뒤 다시 읽음 |
| PAR-FETCH-06 | 같은 갱신은 한 번만 |

---

### 11.5 PatchParser — 파일 하나의 원문 패치 (S-10, #232)

입력은 `worktreeDiff(path:staged:)`, `untrackedPreview(WorktreeFile)`, `commitPatch`, `stashPatch`의 stdout이다. 모두 경로 하나만 지정한다. 줄은 LF로 나눈다.

- **파일 블록.** `diff --git `으로 시작한다. 타입 변경(파일 → 심볼릭 링크)은 같은 경로가 삭제·추가 두 블록으로 나오므로 블록을 여러 개 받는다. `diff --cc `·`diff --combined `(충돌 파일의 결합 diff)는 `isCombined`로 표시하고 본문은 읽지 않는다(다음 블록까지 건너뜀).
- **헤더 줄.** `old mode`, `new mode`, `new file mode`, `deleted file mode`(6자리 8진수), `similarity index`·`dissimilarity index`(`n%`), `rename from`·`rename to`·`copy from`·`copy to`, `index <oid>..<oid>[ <mode>]`, `--- `·`+++ `, `Binary files … differ`. 알 수 없는 헤더 줄은 무시한다(상위 호환).
- **헤더의 경로.** git은 특수 문자가 든 경로를 C 스타일 따옴표로 감싼다(`"tab\there"`, `\303\251` 같은 8진수 바이트). 따옴표를 풀어 바이트로 되돌리고 `GitPath`로 만든다. 따옴표가 맞지 않으면 실패.
- **hunk.** `@@ -a[,b] +c[,d] @@[ 문맥]`. 숫자는 10진수, 개수를 생략하면 1이다. 본문은 **헤더의 개수를 다 채울 때까지** ` `(문맥)·`+`·`-`로 시작하는 줄이고, `\`로 시작하는 줄(`\ No newline at end of file`)은 개수에 세지 않는다. 그래서 `+diff --git`, `-@@ -1 +1 @@` 같은 파일 내용은 헤더로 오인되지 않는다. 개수를 채운 뒤에는 `\` 줄 하나, 다음 hunk 헤더, 다음 파일 블록, 입력 끝만 올 수 있고 그 밖은 실패한다. 개수가 남았는데 다른 줄이 오면 실패한다.
- **줄 번호.** 이전 쪽은 `a`부터, 이후 쪽은 `c`부터 센다. 문맥 줄은 양쪽, `-`는 이전, `+`는 이후만 번호를 가진다.
- **내용.** 줄 내용은 바이트 그대로 둔다(UTF-8이 아니어도, CR이 있어도). 화면에 낼 때 이스케이프한다(제어·bidi 문자, 긴 줄 자르기).
- **서브모듈.** 모드 `160000`(`index … 160000` 또는 mode 줄)이고 본문이 `Subproject commit <oid>`이면 `submodule(old:new:)`로 요약한다.
- **바이너리.** `Binary files … differ`면 `isBinary`. 크기는 diff 출력에 없어서 표시하지 않는다.
- **커밋 OID 줄.** `diff-tree`에 커밋을 하나만 주면(루트 커밋, untracked stash 부모) 맨 앞에 그 커밋의 OID 한 줄을 찍는다. 첫 줄에서만 건너뛴다.
- **`* Unmerged path <경로>`.** 충돌 경로에 `diff --cached`(그리고 일부 unmerged 상태)가 패치 대신 내는 한 줄. 충돌 파일 블록(`isUnmerged`)으로 받는다.
- **`\` 줄 위치.** 내용 줄 바로 뒤에만 올 수 있다. hunk 첫 줄이거나 두 번 연속이면 실패한다. 바이너리 블록 뒤의 hunk도 실패한다.
- **설정이 바꾼 출력.** 저장소 설정(`color.diff=always`, `diff.noprefix`, `diff.mnemonicPrefix`, `diff.submodule=log|diff`, `diff.suppressBlankEmpty`)은 `git diff` 출력 모양을 바꾼다. 카탈로그가 `porcelainDiffOptions`(`--no-color --src-prefix=a/ --dst-prefix=b/ --submodule=short`)와 `-c diff.suppressBlankEmpty=false`로 고정한다(#239). 그래도 파서는 엄격하게 두어 ANSI 코드·`Submodule …` 줄이 오면 실패하고(잘못 읽어 보여 주지 않음), 빈 줄은 개수 안에서 빈 문맥 줄로 받는다.
- **헤더 경로와 문맥 크기에 의존하지 않는다.** 화면 제목은 사용자가 고른 경로를 쓰고, 헤더 경로는 rename·copy 원래 경로 표시에만 쓴다. hunk 끝은 헤더의 개수로 정하므로 `diff.context`가 바꾼 문맥 줄 수(`-U`)와 상관없다. `core.quotePath=false`면 비ASCII 경로가 따옴표 없이 raw 바이트로 오는데, 따옴표를 푼 결과와 같은 바이트가 된다. 그래서 이 두 설정은 카탈로그에 고정하지 않는다(#232 결정).
- **빈 출력.** 변경이 없으면(파일이 원래대로 돌아옴) 블록 0개.
- **잘린 출력.** 마지막 미완성 줄을 버리고, 끝나지 않은 hunk는 받은 줄까지만 두고 `isPartial`.

| 테스트 | 사례 |
|---|---|
| PAR-PATCH-01 | 수정·추가·삭제 파일, 여러 hunk, 문맥 개수 생략, `-0,0`/`+0,0` |
| PAR-PATCH-02 | 헤더를 흉내 내는 내용 줄(`+diff --git`, `-@@`, `++++ b/x`), 개수 불일치·남는 줄은 실패 |
| PAR-PATCH-03 | 따옴표 경로(탭, LF, 8진수 UTF-8, 비UTF-8), `-`로 시작하는 이름, rename/copy와 similarity |
| PAR-PATCH-04 | 모드만 변경, 타입 변경(블록 2개), 바이너리, 서브모듈, 심볼릭 링크, 결합 diff |
| PAR-PATCH-05 | `\ No newline at end of file` 양쪽, CRLF, 비UTF-8 내용, 매우 긴 줄 |
| PAR-PATCH-06 | 잘림: 줄 중간, hunk 헤더 중간, hunk 본문 중간. 빈 출력 |

### 11.6 SubmoduleListParser — `config --file .gitmodules --no-includes -z --get-regexp ^submodule\..*\.path$` (#108)

**형식.** 항목마다 `key␊value␀`. 키는 `submodule.<이름>.path`이고 이름에 `.`·`/`가 들어갈 수 있다. 값이 없는 불리언 키는 `key␀`이다. 일치하는 항목이 없으면 출력이 비고 종료 코드가 1이다 (확인).

```
submodule.libs/a.path␊libs/a␀submodule.v1.2.path␊vendor/b␀
```

- 값은 저장소가 쓴 그대로의 경로다. 절대 경로, `..`, `-`로 시작하는 이름, LF, UTF-8이 아닌 바이트가 올 수 있다. 파서는 걸러내지 않고 `GitPath`로 넘기며, 호출하는 쪽이 `PathValidator.submoduleFolder`로 검증한다.
- 같은 경로는 처음 나온 것 하나만 남긴다. 값이 없거나 빈 항목은 경로가 없으므로 건너뛴다.
- 키가 `submodule.`로 시작하고 `.path`로 끝나지 않으면 실패한다. 잘리지 않은 출력은 `␀`로 끝나야 하고, 잘리면 마지막 레코드를 버린다.
- 서로 다른 경로를 `limit`개(`RepositoryService.maximumListedSubmodules`, 128)까지만 만들고, 넘으면 멈추고 부분 결과로 표시한다(T15).

| 테스트 | 사례 |
|---|---|
| PAR-SUBMOD-01 | 순서 보존, `.`·`/`가 든 이름 |
| PAR-SUBMOD-02 | 빈 출력, 같은 경로 중복 |
| PAR-SUBMOD-03 | 신뢰하지 않는 값(`../`, 절대 경로, LF, UTF-8 아님)을 그대로 보존 |
| PAR-SUBMOD-04 | 값 없는 불리언, 빈 값 |
| PAR-SUBMOD-05 | 잘린 출력, NUL 없는 끝, 다른 키 거부, `limit` 초과는 부분 결과(중복은 세지 않음) |

## 12. 경계 사례 요약

| 경계 사례 | 처리 | 테스트 |
|---|---|---|
| 파일명 공백·개행·탭 | `-z`로 안전, 경로는 나머지 전체 | PAR-STATUS-10, PAR-WT-06 |
| 유니코드 NFD/NFC | 정규화하지 않음, raw 바이트 보존 | PAR-STATUS-10 |
| `-`로 시작하는 파일명, `--`라는 파일명 | 인자로 넘길 때는 `--` 뒤에 둠 (catalog) | PAR-STATUS-10, SEC-T9-xx |
| `:(exclude)` 같은 pathspec 매직 문자열 | `--literal-pathspecs` | PAR-STATUS-10, SEC-T9-xx |
| 올바르지 않은 UTF-8 경로 | `isRepresentable = false`, 파일 단위 동작 끔 | PAR-STATUS-13 |
| detached HEAD | `(detached)`, `detached` 속성 | PAR-STATUS-03, PAR-WT-02 |
| upstream 없음 / 사라짐 | 헤더 유무로 구분 | PAR-STATUS-04, 05 |
| 빈 저장소, unborn 브랜치 | `(initial)`, 로그는 빈 결과 | PAR-STATUS-02, PAR-WT-09 |
| 서브모듈 | `--ignore-submodules=dirty`, `S...` 필드 | PAR-STATUS-11 |
| 매우 긴 출력 잘림 | 마지막 레코드 버림, `isPartial` | PAR-*-잘림 항목 |
| SHA-256 저장소 | 64자리 OID 허용 | PAR-LOG-04 |
| 커밋 메시지의 NUL | git이 NUL 앞에서 자름 | PAR-LOG-08 |

교차 파서 적대적 테스트는 `AdversarialParserTests`(위 표의 각 행을 실제 git 출력과 함께 모든 해당 파서로 확인)와 `ParserPropertyTests`에 있다 (#58). 속성 테스트는 아래 ID를 쓴다.

| 테스트 | 속성 |
|---|---|
| PAR-PROP-01 | 실제 출력을 모든 바이트 위치에서 자른다. `truncated`면 `isPartial`이고 레코드는 전체 결과의 앞부분이다. 아니면 토큰 중간에서 잘린 출력은 `ParseError`, 레코드 경계에서 잘린 출력은 앞부분이다 |
| PAR-PROP-02 | 고정 시드로 실제 출력을 무작위 변형한다. 결과를 내거나 그 파서의 `ParseError`(입력 범위 안의 offset)를 던진다. 크래시·무한 루프·다른 에러 타입은 없다 |
| PAR-PROP-03 | `startIndex`가 0이 아닌 `Data` 슬라이스도 사본과 같은 결과·에러를 낸다 |
