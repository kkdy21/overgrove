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

## 4. StashParser — `stash list -z --format=%gd%x00%H%x00%gs%x00%ct`

**형식.** 레코드마다 필드 4개다. 필드와 레코드 끝 모두 NUL이므로, 토큰을 4개씩 묶는다.

```
stash@{0}␀18351f0f…␀On main: exp: try␀1793853652␀stash@{1}␀1f9538bc…␀WIP on main: 837976f mine␀1793853652␀
```

- `%gd`: `stash@{n}`. 표시와 정렬용이다. git 인자로는 `%H`(OID)를 쓴다. `stash@{n}`은 stash가 바뀌면 다른 항목을 가리키기 때문이다.
- `%gs`: reflog 제목. `^(WIP on|On) (.+?): (.*)$`로 브랜치와 메시지를 뽑는다 (실패하면 원문 그대로 표시).
- `%ct`: epoch 초. 상대 시간(`%cr`)은 쓰지 않고 앱에서 형식을 만든다.
- 토큰 수가 4의 배수가 아니면 `parseFailed`다 (잘린 출력이면 마지막 묶음만 버림).

| 테스트 | 사례 |
|---|---|
| PAR-STASH-01 | `WIP on` / `On` 제목 |
| PAR-STASH-02 | 제목에 콜론, 유니코드 |
| PAR-STASH-03 | 빈 목록 |
| PAR-STASH-04 | 필드 수 불일치 → 실패 |

---

## 5. LogParser

### 5.1 그래프·파일 이력 — `%H%x00%P%x00%an%x00%ae%x00%at%x00%s` + `-z`

레코드마다 필드 6개, 토큰을 6개씩 묶는다.

```
2f833676…␀837976f6… eecf7339…␀t␀t@example.com␀1793853652␀Merge branch 'other'␀
```

| 필드 | 규칙 |
|---|---|
| `%H` | OID 검증. 실패하면 `parseFailed` (재동기화 시도 없음) |
| `%P` | 공백으로 나눈 OID 목록. 루트 커밋은 빈 문자열, 병합은 2개, octopus는 3개 이상 |
| `%an`, `%ae` | 표시용 문자열 |
| `%at` | epoch 초 |
| `%s` | 제목. 커밋 메시지에 NUL이 있어도 git이 NUL 앞에서 자르므로 필드 구조는 깨지지 않는다 (`hash-object --literally`로 만든 객체로 확인) |

- `--graph`는 쓰지 않는다. 레인은 GraphEngine이 `%P`로 계산한다 (ADR-0010).
- `--exclude=refs/stash --all`로 stash 커밋을 뺀다 (확인).
- 서명 관련 포맷(`%G?`, `%GS`, `%GK`, `%GF`, `%GP`, `%GT`)은 금지한다. 쓰면 `gpg.program`이 실행된다 (T7, 확인).

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

---

## 6. RefParser — `for-each-ref --format=%(refname)%00%(objectname)%00%(*objectname)%00%(upstream)%00%(HEAD)%00%(committerdate:unix)%00%(symref)%00%(upstream:track,nobracket)`

**형식.** 레코드는 LF로 끝나고, 필드 8개는 NUL로 나눈다. refname에는 제어 문자가 들어갈 수 없으므로(`check-ref-format` 규칙) LF 구분이 안전하다. 예시는 Apple Git 2.54.0, `LC_ALL=C` 출력이다.

```
refs/heads/both␀2880404c…␀␀refs/remotes/origin/both␀ ␀1793853652␀␀ahead 1, behind 2
refs/heads/main␀9692941d…␀␀refs/remotes/origin/main␀*␀1793853652␀␀
refs/remotes/origin/HEAD␀9692941d…␀␀␀ ␀1793853652␀refs/remotes/origin/main␀
refs/tags/v1␀4fa02a16…␀9692941d…␀␀ ␀␀␀
```

| 필드 | 규칙 |
|---|---|
| `%(refname)` | `refs/heads/`, `refs/remotes/`, `refs/tags/`로 분류. 그 밖의 접두사는 무시 |
| `%(objectname)` | OID. 주석 태그는 태그 객체 OID |
| `%(*objectname)` | 주석 태그가 가리키는 커밋 OID. 경량 태그·브랜치는 빈 값 (확인) |
| `%(upstream)` | 전체 ref 이름 또는 빈 값 |
| `%(HEAD)` | `*`(메인 워크트리가 체크아웃한 브랜치) 또는 공백 |
| `%(committerdate:unix)` | epoch 초. 태그는 비어 있을 수 있음 |
| `%(symref)` | `refs/remotes/origin/HEAD` 같은 심볼릭 ref의 대상 |
| `%(upstream:track,nobracket)` | 빈 값, `ahead N`, `behind M`, `ahead N, behind M`, `gone` 다섯 가지(#54, Apple Git 2.54.0 확인). 빈 값은 `%(upstream)`이 있으면 "같음", 없으면 "upstream 없음"이다. upstream 없이 값이 있으면 형식 위반이다 |

- refname, `%(upstream)`, `%(symref)`는 git 인자로 되돌아갈 수 있으므로 손실 디코딩하지 않는다. 올바른 UTF-8이 아니거나 `FullRefName` 검증(`-`로 시작하는 구성 요소, `..`, `.lock` 등)을 통과하지 못하면 파서 전체를 실패시킨다.
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
- 루트 커밋은 `--root`가 있어야 파일 목록이 나온다 (확인).
- 병합 커밋은 첫 부모를 명시해 두 트리를 비교한다. 기본 동작은 파일 목록을 내지 않는다 (확인).

### 8.2 stash 파일 — `stash show --include-untracked --numstat -z`

numstat 레코드만 나온다. `--include-untracked`가 있으면 untracked 부분 파일도 포함된다 (git 2.32+, 확인). untracked 출신 파일인지는 stash 커밋의 세 번째 부모(`%P`)에 있는지로 구분한다. 이 판별 방법은 Phase 3에서 PAR-NUMSTAT-05로 확정한다.

| 테스트 | 사례 |
|---|---|
| PAR-NUMSTAT-01 | 추가·수정·삭제 |
| PAR-NUMSTAT-02 | 이름 변경 (빈 경로 필드) |
| PAR-NUMSTAT-03 | 바이너리 `-` |
| PAR-NUMSTAT-04 | raw + numstat 합치기, 상태 문자 |
| PAR-NUMSTAT-05 | stash untracked 부분 |

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

### 10.1 GHAuthParser — `gh auth status --hostname github.com --json hosts`

```json
{"hosts":{"github.com":[{"active":true,"gitProtocol":"https","host":"github.com","login":"<login>","scopes":"...","state":"success","tokenSource":"keyring"}]}}
```

- 로그인 판정: `hosts["github.com"]`에 `active == true && state == "success"`인 항목이 있다.
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
| `url` | URL (`https://github.com/`로 시작해야 함) | 예 |

| 테스트 | 사례 |
|---|---|
| PAR-GH-01 | 로그인 상태 |
| PAR-GH-02 | 미로그인, state 실패, 빈 hosts |
| PAR-GH-03 | 이슈 목록 (라벨, 담당자, 선택 필드 누락) |
| PAR-GH-04 | 예상 밖 JSON → 실패 |

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

### 11.3 IssueRefExtractor (G8)

| 출처 | 규칙 |
|---|---|
| 브랜치명 | `^(?:feat\|fix\|docs\|test\|chore\|spike\|refactor\|perf\|ci)/(\d{1,7})-` 우선, 다음으로 `(?:^\|/)(\d{1,7})-` |
| 커밋 제목 | `#(\d{1,7})\b`. `owner/repo#n` 형태는 같은 저장소일 때만 매칭 |
| 커밋 트레일러 | `^Refs: #(\d{1,7})$`, `^(?:Closes\|Fixes\|Resolves) #(\d{1,7})` (`%B`에서) |

매칭된 번호는 이슈 목록에 있을 때만 링크로 표시한다. 목록에 없으면 회색 `#n`으로 표시한다.

| 테스트 | 사례 |
|---|---|
| PAR-ISSUE-01 | 브랜치 규칙 매칭 |
| PAR-ISSUE-02 | 제목의 `#n`, 오탐(`C#`, `#define`) 배제 |
| PAR-ISSUE-03 | 트레일러 |

---

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
