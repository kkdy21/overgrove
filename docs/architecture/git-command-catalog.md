# git·gh 명령 카탈로그

> 상태: Accepted (Phase 2 게이트, 2026-11-05) · 관련: ADR-0004, ADR-0008, ADR-0009, ADR-0010, ADR-0011, [overview.md](overview.md), [parsing-spec.md](parsing-spec.md), [../design/security-review.md](../design/security-review.md)

이 문서는 앱이 실행할 수 있는 **모든 외부 명령의 allowlist**다. 여기에 없는 명령은 코드에 타입으로 존재하지 않는다. 새 명령이 필요하면 이 문서를 먼저 고치고, PR에 `area:security` 라벨을 붙인다.

인자 배열은 Swift `Process.arguments`에 그대로 들어가는 형태로 적는다. `<...>`는 검증을 통과한 값이 들어가는 자리다. 표에 적은 동작은 Apple Git 2.50.1에서 확인했다. 확인 기록은 [security-review.md §4](../design/security-review.md)에 있다.

---

## 1. 최종 인자 조립 순서

```
<git 실행 파일>
  [공통 보안 인자 §2.1]
  [동적 무력화 인자 §2.2 — RepoConfigInspector 결과]
  [fetch 전용 인증 인자 §2.3 — FetchCommand만]
  <서브커맨드> <서브커맨드 인자 §3, §4>
```

- `-c` 인자는 서브커맨드 **앞**에 둔다. 명령줄 `-c`는 설정 파일보다 나중에 읽히므로 단일값 키는 덮어쓴다.
- 다중값 키는 다르다. 빈 값으로 목록을 초기화할 수 있는 키(`credential.helper`)만 `-c`로 다루고, 첫 값이 이기는 키(`remote.<n>.uploadpack`, `core.gitProxy`)는 서브커맨드 옵션이나 환경 변수로 다룬다 (실험 확인).
- 작업 디렉터리는 `Process.currentDirectoryURL`로 정한다. `-C`는 쓰지 않는다.
- 공통 인자는 `GitClient`가 붙인다. `GitCommand` case는 서브커맨드 이후만 정의한다. 테스트는 최종 배열 전체를 스냅샷으로 검증한다 (SEC-T9-01).

---

- **저장소 경로.** 메인 워크트리(`Repository.rootURL`)다. bare 저장소는 메인 워크트리가 없으므로(`rootURL == nil`, #222) 공통 git 디렉터리에서 실행한다. 워크트리 경로가 필요한 명령(`status`, `worktreeDiff`, `untrackedPreview`, `fileHistory`)은 `worktree list`가 나열하고 검증한 워크트리에서만 실행한다.
- **검사 순서.** `version`, `probeGitDirectory`, `probeRepository`, `configList`를 뺀 모든 명령은 `RepoConfigInspector` 결과(`RepoSafetyContext`)가 있어야 실행된다. `GitClient`가 강제한다.

## 2. 공통 인자와 환경

### 2.1 공통 보안 인자 (모든 git 호출)

| 인자 | 목적 | 위협 |
|---|---|---|
| `--no-pager` | 페이저 실행 방지 | T10 |
| `--no-optional-locks` | 조회 중 `index.lock`을 잡지 않음, index 갱신 쓰기 방지. `git diff`의 자동 refresh는 막지 못한다(`diff.autoRefreshIndex` 행 참고) | T13 |
| `--literal-pathspecs` | `:(exclude)`, glob 등 pathspec 매직을 끔 | T9 |
| `-c core.fsmonitor=false` | fsmonitor 훅 실행 방지. 서브프로세스(서브모듈)에도 전파됨 (확인) | T1 |
| `-c core.hooksPath=/dev/null` | hooks 디렉터리의 훅 실행 방지 (fetch의 `reference-transaction` 포함, 확인). 설정형 hook(`hook.<이름>.*`, git 2.54+)은 이 인자로 막히지 않으므로 이름별 `-c hook.<이름>.enabled=false`로 끈다(§2.2, #354) | T2 |
| `-c core.askPass=` | 로컬 `core.askPass` 실행 방지 (확인) | T12 |
| `-c protocol.ext.allow=never` | `ext::` 원격과 `insteadOf`로 바꿔치기한 `ext::` 차단 (확인). `GIT_ALLOW_PROTOCOL`(§2.4)과 겹치는 심층 방어 | T5 |
| `-c protocol.fd.allow=never` | `fd::` 원격 차단. 기본값에서는 허용되고 정지를 일으킴 (확인) | T5, T15 |
| `-c alias.remote-https= -c alias.remote-ssh= -c alias.remote-git= -c alias.remote-file= -c alias.remote-http= -c help.autocorrect=0` | 관련 저장소 설정 무력화. fetch 전 원격 형태 검사(§4)와 겹치는 심층 방어 (#350, git 2.36.6·Apple Git 2.54.0·Homebrew 2.54.0 확인) | T5 |
| `-c core.alternateRefsCommand=` | `objects/info/alternates`가 있는 저장소를 fetch할 때 로컬 `core.alternateRefsCommand`가 실행되는 것을 막음. 빈 값으로 덮어도 fetch는 성공 (확인: [fixtures.md §8](../testing/fixtures.md)) | T5 |
| `-c log.showSignature=false` | 로컬 `log.showSignature=true`로 인한 `gpg.program` 실행 방지 (확인) | T7 |
| `-c gc.auto=0` | 자동 gc 방지 | T8 |
| `-c maintenance.auto=false` | fetch 뒤 `git maintenance run --auto` 실행 방지 (확인) | T8 |
| `-c diff.autoRefreshIndex=false` | `git diff`가 stat만 바뀐 경로를 diff할 때 index를 새로 고쳐 쓰는 것을 막음. `--no-optional-locks`·`GIT_OPTIONAL_LOCKS=0`은 이 쓰기를 막지 못한다. patch 출력은 그대로다 (확인, #208) | T13 |
| `-c color.ui=never` | 출력에 ANSI 코드가 섞이지 않게 함. 저장소 로컬 `color.diff=always`는 이 값을 이기므로 porcelain diff에는 `--no-color`를 따로 붙인다(§3, #239) | 파싱 안정성 |
| `-c diff.suppressBlankEmpty=false` | 저장소 로컬 `diff.suppressBlankEmpty`가 patch의 빈 문맥 줄 앞 공백을 지우지 못하게 함. 이 설정은 명령줄 옵션이 없다 (확인, #239) | T3, 파싱 무결성 |
| `-c i18n.logOutputEncoding=UTF-8` | 저장소 로컬 `i18n.logOutputEncoding`·`i18n.commitEncoding`이 포맷된 출력 전체(`-z` 구분자 포함)를 다시 인코딩하지 못하게 함. JOHAB·CP1361은 메시지의 전각 문자를 NUL로 바꿔 필드를 밀고 가짜 레코드를 만든다 (확인, E41, #205) | T15, 파싱 무결성 |
| `-c log.follow=false` | 저장소 로컬 `log.follow=true`가 경로 하나짜리 `git log`를 rename 추적으로 바꾸지 못하게 함. `fileHistory(follow: false)`가 `--follow`만 빼던 탓에 S-09의 "Follow renames"를 꺼도 rename 이전 커밋이 나왔다. 추적이 필요하면 `fileHistory`가 `--follow`를 직접 넘기고, 옵션이 설정보다 우선한다. `log.follow`는 git 2.6부터 있어 최소 지원 버전(2.36)에서 동작한다 (확인, #310) | 표시 정확성 |
| `-c log.mailmap=false -c mailmap.file= -c mailmap.blob=` | 저장소 로컬 mailmap 설정이 저장소 밖 파일을 읽게 하지 못함. FIFO면 `git log`가 시간 제한까지 멈춘다(2.36.6·2.54.0 확인). 앱은 커밋에 기록된 이름을 그대로 보여 준다(`%an`, #356) | T15 |

diff를 만드는 서브커맨드(`diff`, `diff-tree`, `stash show`, `log -p`)에는 서브커맨드 인자로 `--no-ext-diff --no-textconv`를 반드시 붙인다 (T3). `git diff`는 기본으로 외부 diff 드라이버를 실행한다 (확인).

### 2.2 동적 무력화 인자 (RepoConfigInspector, ADR-0009)

신뢰하지 않는 scope(`local`, `worktree`)에서 `filter.<d>.*`를 찾으면, 드라이버마다 다음 인자를 모든 호출에 붙인다.

```
-c filter.<d>.clean= -c filter.<d>.smudge= -c filter.<d>.process= -c filter.<d>.required=false
```

- 빈 clean 명령은 필터를 끈다.
- `required=true`인 상태에서 clean만 비우면 `fatal: clean filter failed`가 난다. 그래서 `required=false`도 함께 넣는다 (확인).
- `<d>` 드라이버 이름은 `[A-Za-z0-9._-]{1,64}`만 허용한다. 이 형식에 맞지 않는 이름이 있으면 무력화 인자를 만들 수 없다. 이때는 `configInspectionFailed`로 조회를 막는다 (fail closed).

같은 scope에서 설정형 hook(`hook.<이름>.*`, git 2.54+)을 찾으면 이름마다 다음 인자를 모든 호출에 붙인다(#354).

```
-c hook.<이름>.enabled=false
```

- 이름은 바이트로 구분한다. 2.54 미만 git은 이 키를 무시한다.
- 이름에 `=`(git이 `-c`를 첫 `=`에서 자른다), 제어 문자, 손실 디코딩이 있거나 256바이트를 넘으면, 또는 이름이 256개를 넘으면 무력화 인자를 만들 수 없다. 이때는 `configInspectionFailed`로 조회를 막는다(fail closed).

### 2.3 fetch 전용 인증 인자

```
-c credential.helper=
  [신뢰 scope의 credential.*helper 항목을 원래 순서와 키 그대로 재삽입]
[신뢰하지 않는 scope에서 false로 설정된 http.sslVerify, http.<url>.sslVerify 키마다: -c <같은 키>=true]
[신뢰하지 않는 scope의 http.proxy, http.<url>.proxy, remote.<name>.proxy 키마다: -c <같은 키>=<신뢰 scope의 같은 키 값, 없으면 빈 값>]
[신뢰하지 않는 scope의 http.cookieFile, http.<url>.cookieFile 키마다: -c <같은 키>=, http.saveCookies, http.<url>.saveCookies 키마다: -c <같은 키>=false]
[신뢰하지 않는 scope의 credential[.<url>].protectProtocol, credential[.<url>].sanitizePrompt 키마다: -c <같은 키>=true]
```

- 재삽입 예: Apple Git 내장 설정(`unknown` scope)의 `credential.helper=osxkeychain`, `gh auth setup-git`이 global에 쓴 `credential.https://github.com.helper=`(빈 값)와 `credential.https://github.com.helper=!/opt/homebrew/bin/gh auth git-credential`.
- generic 키 초기화(`credential.helper=`)는 그 이전에 읽힌 URL별 helper까지 비운다 (확인). 그래서 신뢰 항목은 반드시 초기화 **뒤에** 다시 넣는다.
- `http.<url>.sslVerify`는 URL별 키가 generic 키보다 우선한다. 그래서 같은 URL 키로 덮어써야 한다 (확인: `config --get-urlmatch`).
- 프록시: `remote.<name>.proxy`는 그 원격에서 `http.proxy`보다 우선한다. 저장소가 고른 프록시는 신뢰 helper가 내준 자격 증명이 담긴 요청을 볼 수 있으므로(#150, #355) 세 형태 모두 같은 키로 덮는다. 덮는 값은 그 URL에 대해 신뢰 scope가 주는 실효 프록시다(`remote.<name>.proxy`는 같은 키의 신뢰 값 → 원격 URL에 맞는 가장 구체적인 신뢰 `http.<url>.proxy` → 신뢰 `http.proxy`, `http.<url>.proxy`는 그 URL에 맞는 신뢰 값 → 신뢰 `http.proxy`). 없으면 빈 값(프록시 없음)이다. 빈 값을 넣으면 사용자의 `http.proxy`보다 구체적이어서 회사 프록시 환경에서 fetch가 실패하기 때문이다. URL 대조는 git의 urlmatch 규칙(scheme, `*` 라벨이 있는 host, port, path 접두사, user. 우선순위는 host → path → user, 같으면 나중 값)을 따르되 percent 디코딩은 하지 않는다. 무엇을 고르든 신뢰 값이거나 빈 값이므로 대조가 어긋나도 보안 문제는 아니다 (`TrustedProxies`).
- 덮어쓰는 키의 subsection에 `=`가 있거나 UTF-8이 아니면(디코딩에서 U+FFFD) 같은 키로 덮을 수 없으므로 조회를 막는다(#355 리뷰).
- 쿠키: 저장소가 고른 파일을 쿠키 저장소로 읽고 쓰지 않게 한다. generic 키는 fetch overrides가 끄고(`-c http.cookieFile= -c http.saveCookies=false`, 아래 §3, 사용자 값 포함), 저장소의 URL별 키는 generic 덮어쓰기를 이기므로 같은 키로 끈다 (확인, 2.36.6·2.54.0, #355). 사용자의 URL별 키는 그대로 둔다.
- 키 중복은 바이트로 비교한다. git은 정준 동치(NFC/NFD)인 subsection을 별개 키로 보므로, 문자열 동치로 합치면 하나가 덮어쓰기에서 빠진다(#355).

### 2.4 환경 변수 (allowlist, 부모 환경 미상속)

| 변수 | 값 | 대상 |
|---|---|---|
| `LC_ALL`, `LANG` | `C` | 모든 git |
| `GIT_TERMINAL_PROMPT` | `0` | 모든 git |
| `GIT_OPTIONAL_LOCKS` | `0` | 모든 git (`--no-optional-locks`와 중복 방어) |
| `GIT_PAGER`, `PAGER` | `cat` | 모든 git |
| `GIT_ASKPASS`, `SSH_ASKPASS` | 빈 문자열 | 모든 git (빈 `GIT_ASKPASS`는 `core.askPass`보다 우선해 실행을 막음, 확인) |
| `GIT_PROXY_COMMAND` | 빈 문자열 | 모든 git (로컬 `core.gitProxy` 무력화, 확인) |
| `GIT_ALLOW_PROTOCOL` | fetch: `https:ssh:git:file:http`. 신뢰하지 않음 저장소의 fetch(#107): `file`을 뺀 `https:ssh:git:http`. 조회·기본값: 빈 값 | 조회(`GitClient.run`)는 전송을 쓰지 않는다. partial clone에서 누락 객체가 필요한 조회가 promisor 원격으로 lazy fetch하며 저장소의 uploadpack·credential helper를 실행하는 것을 막는다(#212). fetch는 (내장 전송만 허용. 저장소의 `protocol.<이름>.allow`를 포함한 모든 설정보다 우선해, 저장소가 고른 `git-remote-<helper>`를 막음, 확인, #161) |
| `GIT_NO_LAZY_FETCH` | `1` | 모든 git (promisor lazy fetch 금지, #212). 모든 경로를 막는 것은 2024년 5월 보안 릴리스(2.45.1, 2.44.1, 2.39.4·2.40.2·2.41.1·2.42.2·2.43.4 백포트)부터다. 백포트가 없는 2.44.0 이하는 무시하고, 2.45.0은 fetch 중의 lazy fetch를 막지 못한다(#317). 조회는 빈 `GIT_ALLOW_PROTOCOL`이 막고, fetch는 전송이 필요하므로 `lazyFetchControlVersion`(2.45.1) 미만에서 partial clone(promisor 설정 또는 `.promisor` pack, security-review.md T5)이면 `GitClient.fetch`가 실행을 거부한다(fetch 중 lazy fetch가 로컬 uploadpack을 실행하기 때문, #213 보안 검토) |
| `GIT_SSH_COMMAND` | 신뢰 scope의 `core.sshCommand` 값, 없으면 `ssh -o BatchMode=yes` | 모든 git (환경 변수가 로컬 설정보다 우선, 확인) |
| `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SSH_AUTH_SOCK` | 부모 값 그대로 | 모든 git |
| `PATH` | `/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin` | 모든 git |

전달하지 않는 변수의 예: `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_CONFIG*`, `GIT_CONFIG_PARAMETERS`, `GIT_EXEC_PATH`, `GIT_SSH`, `GIT_EXTERNAL_DIFF`, `GIT_TRACE*`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `DYLD_*`.

### 2.5 실행 제한

| 구분 | 타임아웃 | stdout 상한 | stderr 상한 |
|---|---|---|---|
| 기본 (조회) | 15초 | 10MB | 64KB |
| fetch | 120초 | 1MB | 256KB (진행 메시지 포함) |
| gh | 15초 | 5MB | 64KB |

상한을 넘으면 읽기를 멈추고 프로세스를 종료한 뒤 `truncated=true`로 결과를 돌려준다. 파서는 잘린 마지막 레코드를 버리고 경고를 낸다 ([parsing-spec.md §1](parsing-spec.md)).

---

## 3. ReadOnlyGitCommand

| case | 서브커맨드 인자 배열 | 작업 디렉터리 | 파서 → 모델 | 위협 |
|---|---|---|---|---|
| `version` | `["version"]` | 중립 디렉터리(앱 임시 디렉터리) | `VersionParser` → 버전 값 | — |
| `probeGitDirectory` | `["rev-parse", "--path-format=absolute", "--git-common-dir", "--absolute-git-dir", "--is-bare-repository", "--is-inside-work-tree"]` | 등록 경로, bare 판별 시 공통 git 디렉터리 | `GitDirectoryProbeParser` → bare 여부와 git 디렉터리 (#222). `--show-toplevel`이 없어 bare 저장소와 `.git` 안에서도 성공한다 | T14 |
| `probeRepository` | `["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir", "--is-bare-repository"]` | 등록 경로(워크트리 안일 때만), 나열된 워크트리 | 줄 단위 → `Repository` | T14 |
| `configList` | `["config", "--list", "--show-scope", "-z", "--includes"]` | 저장소 경로 | `ConfigParser` → 보안 보고서, 원격 목록 | T4–T8 |
| `worktreeList` | `["worktree", "list", "--porcelain", "-z"]` | 저장소 경로 | `WorktreeParser` → `[Worktree]` | — |
| `status` | `["status", "--porcelain=v2", "-z", "--branch", "--show-stash", "--untracked-files=all", "--ignore-submodules=dirty"]` | 워크트리 경로 | `StatusParser` → `WorkingState`, `UpstreamStatus` | T1, T4 |
| `refs` | `["for-each-ref", "--format=%(refname)%00%(objectname)%00%(*objectname)%00%(upstream)%00%(HEAD)%00%(committerdate:unix)%00%(symref)%00%(upstream:track,nobracket)", "refs/heads", "refs/remotes", "refs/tags"]` | 저장소 경로 | `RefParser` → `[Branch]`, `[Tag]` (로컬 브랜치의 ahead/behind 포함) | — |
| `aheadBehind(local:upstream:)` | `["rev-list", "--left-right", "--count", "--end-of-options", "<upstream full ref>...<local full ref>"]` | 저장소 경로 | `RevListParser` → (behind, ahead) | T9 |
| `stashList` | `["log", "-g", "-z", "--ignore-missing", "--format=%gd%x00%H%x00%gs%x00%ct%x00%P", "refs/stash", "--"]` | 저장소 경로 | `StashParser` → `[Stash]`. `%P`는 기준 커밋(첫 부모)과 index·untracked 커밋 유무(S-04, #71). `git stash list`가 내부에서 실행하는 reflog 조회와 같은 바이트를 내지만(Apple Git 2.50.1, git 2.54.0에서 비교), `stash list`와 달리 작업 트리가 필요 없어 bare 저장소에서도 동작한다(#222). `refs/stash`가 없으면 빈 출력이다 | T7 (공통 `-c log.showSignature=false`) |
| `stashFiles(oid:)` | `["stash", "show", "--include-untracked", "--numstat", "-z", "--no-ext-diff", "--no-textconv", "--end-of-options", "<oid>"]` | 저장소 경로. `stash show`는 작업 트리가 필요하므로 bare 저장소에서는 검증된 링크 워크트리에서 실행한다(#222) | `NumstatParser` → `StashDetail` | T3, T9 |
| `stashPatch(oid:path:originalPath:fromUntracked:)` | 추적 파일: `["diff-tree", "-p", "-M", "--no-ext-diff", "--no-textconv", "--end-of-options", "<oid>^1", "<oid>", "--", "<path>"]`<br>untracked 출신: `["diff-tree", "-p", "-M", "--no-ext-diff", "--no-textconv", "--root", "--end-of-options", "<oid>^3", "--", "<path>"]`<br>rename이면 끝이 `"--", "<이전 경로>", "<새 경로>"`(아래 rename 규칙) | 저장소 경로 | 원문 패치 → S-10. `git stash show`는 경로 지정을 받지 않는다(#148 리뷰에서 확인) | T3, T9 |
| `graphPage(skip:limit:)` | `["log", "--branches", "--remotes", "--tags", "--exclude=refs/*", "--all", "--date-order", "-z", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%(trailers:key=Co-authored-by,valueonly,unfold,separator=%x1f)", "--skip=<n>", "-n", "<limit>"]` | 저장소 경로 | `LogParser` → `[CommitNode]`(co-author 포함, #160) → GraphEngine. ref 범위는 브랜치·원격 추적 ref·태그와 모든 워크트리의 HEAD뿐이다(`--exclude=refs/* --all`은 HEAD만 더함). notes·`refs/prefetch`·`refs/original`·stash는 따라가지 않으며, 이 범위가 페이지 캐시 키 `GraphRefSet`과 같다(#308) | T7 |
| `commitMeta(oid:)` | `["log", "-1", "-z", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%ce%x00%ct%x00%B", "--end-of-options", "<oid>"]` | 저장소 경로 | `LogParser` → `CommitDetail` | T7, T9 |
| `commitFiles(oid:)` | 루트·일반 커밋: `["diff-tree", "-r", "-z", "--raw", "--numstat", "-M", "--no-ext-diff", "--no-textconv", "--no-commit-id", "--root", "--end-of-options", "<oid>"]`<br>병합 커밋: `[..., "--end-of-options", "<first parent oid>", "<oid>"]` | 저장소 경로 | `NumstatParser`(raw+numstat) → `CommitDetail.files` | T3, T9 |
| `commitPatch(oid:parent:path:originalPath:)` | `["diff-tree", "-p", "-M", "--no-ext-diff", "--no-textconv", "--root", "--end-of-options", "<parent oid 또는 생략>", "<oid>", "--", "<path>"]`<br>rename이면 끝이 `"--", "<이전 경로>", "<새 경로>"`(아래 rename 규칙) | 저장소 경로 | 원문 패치 → S-10 | T3, T9 |
| `worktreeDiff(path:originalPath:staged:)` | `["diff", "--no-ext-diff", "--no-textconv", "-M", "--ignore-submodules=dirty", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short", (staged ? "--cached" : 생략), "--", "<path>"]`<br>rename이면 끝이 `"--", "<이전 경로>", "<새 경로>"`(아래 rename 규칙) | 워크트리 경로 | 원문 패치 → S-10 | T3, T4, T9 |
| `worktreeNumstat(staged:)` | `["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", "-M", "--ignore-submodules=dirty", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short", (staged ? "--cached" : 생략)]` | 워크트리 경로 | `NumstatParser.parseWorktreeFiles` → `WorkingLineCounts` (S-02 줄 수, #230) | T1, T3, T4, T13 |
| `untrackedPreview(WorktreeFile)` | `["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short", "--", "/dev/null", "<path>"]` (종료 코드 1이 정상) | 워크트리 경로 | 원문 패치 → S-10 | T3, T14 |
| `fileHistory(path:follow:limit:)` | `["log", "--follow"(follow일 때만), "-z", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%(trailers:key=Co-authored-by,valueonly,unfold,separator=%x1f)", "--numstat", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short", "-n", "<limit>", "--", "<path>"]`. `--numstat`은 커밋마다 그 파일의 `+n −m`과 그 커밋에서의 경로(rename이면 이전 경로도)를 준다(S-09, #70). `--skip`은 쓰지 않는다: `--follow`와 함께 쓰면 엉뚱한 커밋을 건너뛰어 다음 페이지가 rename 커밋을 다시 보여 줬다(확인). 다음 페이지는 `limit`을 늘려 다시 읽고 앞부분을 버린다. `limit`이 100,000을 넘으면 잘린 이력으로 표시한다 | 워크트리 경로 | `LogParser.parseFileHistory` → `[FileHistoryEntry]` | T3, T7, T9, T15 |
| `compareFiles(base:includeWorkingTree:)` | `["diff", "-z", "--raw", "--numstat", "-M", "--no-abbrev", "--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short", "--merge-base", "--end-of-options", "<base full ref>", ("HEAD" 또는 작업 트리 포함이면 생략), "--"]` | 워크트리 경로 | `NumstatParser.parseCommitFiles` → `WorktreeComparison.files` | T3, T4, T9, T13 |
| `comparePatch(base:path:originalPath:includeWorkingTree:)` | `["diff", "-p", "-M", "--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short", "--merge-base", "--end-of-options", "<base full ref>", ("HEAD" 또는 생략), "--", "<path>"]`<br>rename이면 끝이 `"--", "<이전 경로>", "<새 경로>"`(아래 rename 규칙) | 워크트리 경로 | 원문 패치 → S-11 | T3, T4, T9, T13 |
| `commitsAhead(base:limit:)` | `["log", "-z", "--format=<graphPage와 같은 형식>", "-n", "<limit>", "--end-of-options", "<base full ref>..HEAD", "--"]` | 워크트리 경로 | `LogParser` → `WorktreeComparison.commits` | T7, T9 |

보충 규칙:

- **원격 이름과 URL**은 `configList` 결과의 `remote.<name>.url`에서 얻는다. 별도 명령을 쓰지 않는다. URL은 표시 전에 `CredentialMasker`를 거친다.
- **ahead/behind**는 워크트리마다 `status`의 `# branch.ab +A -B` 헤더에서 얻는다. 사이드바 LOCAL의 로컬 브랜치는 `refs`의 `%(upstream:track,nobracket)`에서 한 번에 얻고, 브랜치마다 `rev-list`를 실행하지 않는다(#54, 2026-11-06 측정 S5). `aheadBehind`는 upstream이 아닌 기준 브랜치와의 ahead/behind(비교 카드, S-11, #157)에만 쓴다. `rev-list` 출력은 `<behind>\t<ahead>`다 (확인).
- **그래프 페이지**는 `--skip`과 `-n`으로 나눈다. 같은 ref 집합이면 순서가 결정적이라 GraphEngine이 열린 레인 상태를 이어서 계산한다. ref 집합 해시가 바뀌면 처음부터 다시 계산한다. 10만 커밋에서 뒤쪽 페이지의 `--skip` 비용이 PB-4를 넘으면, 스트리밍 읽기 모드(한 프로세스의 출력을 페이지 단위로 소비)로 바꾼다. 이 결정은 Phase 3 성능 측정 뒤에 ADR-0010을 갱신해 남긴다.
- **untrackedPreview**는 `PathValidator.worktreeFile`이 만든 `WorktreeFile`만 받는다(상대 경로, `..` 없음, 실제 위치가 워크트리 안, 일반 파일 또는 심볼릭 링크 — FIFO는 git을 멈추게 하므로 거부). 심볼릭 링크는 내용 대신 링크 대상 문자열만 보여 준다 (T14).
- **두 커밋 비교(S-12, #122)는 새 명령 없이 `commitFiles`·`commitPatch`를 쓴다.** 부모 자리(`firstParent`, `parent`)에 기준 커밋을 넘기면 `diff-tree`가 기준→대상 두 트리를 비교한다. 두 OID 모두 그래프가 불러온 커밋이고 `ObjectID`로 검증되어 `--end-of-options` 뒤에 온다. `diff-tree`는 plumbing이라 저장소의 diff 설정을 읽지 않는다. 기준과 대상 사이의 커밋 목록은 `commitsAhead`가 브랜치 ref만 받아 1차에서 뺐다(later).
- **rename 패치는 두 경로를 다 넘긴다(#309)**. 패치 case(`stashPatch`·`commitPatch`·`worktreeDiff`·`comparePatch`)는 `originalPath`(이전 이름)를 받는다. 값이 있고 새 경로와 다르면 경로 지정이 `["--", "<이전 경로>", "<새 경로>"]`가 된다. 새 경로만 넘기면 `-M`이 짝을 찾지 못해 rename을 통째로 추가된 파일로 보여 줬다(확인). 두 경로 모두 `--` 뒤에 두고 `--literal-pathspecs`가 적용되므로 인자 규칙은 같다. 두 번째 경로도 파일 목록(status·numstat·raw 출력)에서 온 값이고 UTF-8로 표현되지 않으면 `unrepresentable`로 거부한다.
- **작업 트리를 보는 diff는 `--ignore-submodules=dirty`를 붙인다(#239)**. 경로가 서브모듈이면 git은 서브모듈이 더러운지 보려고 서브모듈 안에서 `status`를 실행한다. 그때 서브모듈 자체의 `.git/modules/<sub>/config`에 있는 filter가 실행되는데, 설정 검사는 상위 저장소 설정만 읽는다(확인, SEC-T4-05). `status`, `worktreeDiff`, 기준 브랜치 비교(`compareFiles`·`comparePatch`, #157)가 이 인자를 쓴다. `--cached`는 서브모듈 안을 보지 않지만 같은 인자를 붙인다. 서브모듈 커밋이 바뀐 것은 그대로 보인다. 다른 diff 계열(`stashFiles`·`stashPatch`·`commitFiles`·`commitPatch`·`fileHistory`)은 트리끼리 비교하므로 서브모듈 작업 트리를 보지 않고, `untrackedPreview`는 일반 파일·심볼릭 링크만 받는다.
- **porcelain diff 출력 고정(#239)**: `git diff`(porcelain)는 저장소 로컬 diff 설정을 읽어 출력 모양을 바꾼다. plumbing인 `diff-tree`는 읽지 않는다 (Apple Git 2.50.1 확인). 그래서 porcelain diff case(`worktreeDiff`, `worktreeNumstat`, `untrackedPreview`, `comparePatch`, `compareFiles`)에 `ReadOnlyGitCommand.porcelainDiffOptions`를 붙인다. numstat·raw 출력은 아래 설정에 영향받지 않았지만(확인), 규칙을 하나로 두려고 같은 인자를 붙인다.

  | 저장소 설정 | 영향 | 막는 인자 |
  |---|---|---|
  | `color.diff=always` | 공통 `color.ui=never`를 이겨 ANSI 코드가 섞인다 | `--no-color` |
  | `diff.noprefix`, `diff.mnemonicPrefix`, `diff.srcPrefix`, `diff.dstPrefix`(2.45+) | `a/`·`b/` 접두사가 없어지거나 `i/`·`w/`·임의 값이 된다 | `--src-prefix=a/ --dst-prefix=b/`. 명령줄이 저장소 값보다 우선한다(확인). `--default-prefix`는 2.41+라 쓰지 않는다 |
  | `diff.submodule=log\|diff` | `Submodule …` 줄이 생기고, `=diff`면 서브모듈 쪽 파일 diff까지 붙는다(서브모듈 쪽 git 작업) | `--submodule=short` |
  | `diff.suppressBlankEmpty` | 빈 문맥 줄의 앞 공백이 사라진다 | 공통 `-c diff.suppressBlankEmpty=false`(명령줄 옵션 없음) |

  모두 git 2.36에 있다. 고정하지 않은 설정 중 `diff.context`(문맥 줄 수)와 `core.quotePath`(비 ASCII 경로 따옴표)도 출력 모양을 바꾼다. 둘 다 올바른 patch를 내므로 표시 문제로 보고 따로 다룬다.
- **기준 브랜치 비교(#157)**는 워크트리 브랜치가 기준 브랜치에서 갈라진 지점(merge-base)부터 비교한다. GitHub PR의 "Files changed"와 같은 결과다. 그래서 기준 브랜치가 따로 진행한 변경은 나오지 않는다.
  - `--merge-base <base> HEAD`는 커밋만 비교한다. `HEAD`를 빼면 미커밋 추적 변경까지 포함한다(git 2.30+, Apple Git 2.50.1 확인).
  - `git diff --raw`는 `diff-tree`와 달리 객체 이름을 줄여 쓰므로 `--no-abbrev`를 붙인다(확인). 작업 트리 쪽 객체 이름은 0으로 채워지며, 파서는 그대로 받는다(파일 목록에는 객체 이름을 쓰지 않는다).
  - 기준 ref는 `FullRefName`으로 검증한 전체 이름만 받고 `--end-of-options` 뒤에 둔다. 끝의 `--`는 ref와 같은 이름의 파일이 경로로 읽히지 않게 한다. `FullRefName`에는 `..`가 없으므로 `<base>..HEAD`는 한 범위로만 읽힌다.
  - `--ignore-submodules=dirty`(status와 같다): 작업 트리를 비교하면 git은 서브모듈이 더러운지 보려고 서브모듈 안에서 `status`를 실행한다. 그때 검사하지 않은 서브모듈 자체의 filter가 실행된다(확인, SEC-T4-05). 서브모듈의 커밋 변경은 그대로 나온다.
  - untracked 파일은 git diff에 나오지 않는다. 그 워크트리의 마지막 `status` 결과에서 붙인다.
  - 작업 트리를 읽으므로 셋 다 설정 검사 뒤에만 실행한다(`requiresInspection`). 서비스는 `status`와 같은 워크트리 소속 확인을 거친다(#226).
  - stat만 바뀐 파일이 있어도 공통 인자 `diff.autoRefreshIndex=false`가 index 갱신 쓰기를 막는다. 이 설정을 빼면 `git diff --merge-base`도 index를 다시 쓴다(확인, SEC-T13-02).
  - 조회는 전송을 허용하지 않으므로, partial clone에서 없는 blob이 필요하면 `partialCloneObjectMissing`이 된다(#212).
  - 기본 기준: `refs/remotes/origin/HEAD`의 대상 → `refs/heads/main` → `refs/heads/master`. 셋 다 `refs` 결과에 있는 브랜치일 때만 쓴다. 사용자는 다른 로컬·원격 브랜치를 고를 수 있다.
  - ahead/behind는 HEAD가 브랜치에 있을 때 `aheadBehind(local:upstream: <base>)`로 구한다.
  - 갈라진 지점이 없으면(관련 없는 이력) git이 `fatal: no merge base found`를 낸다 → `noMergeBase`(§6).
- **worktreeNumstat** (#230): WIP 상세(S-02)의 파일별 `+n −m`. 포커스 워크트리를 상세로 볼 때만 staged·unstaged 두 번 실행한다. 경로 인자가 없다(워크트리 전체). git 2.54.0에서 확인했다.
  - `-M`: status와 같이 rename을 새 경로 하나로 센다. status의 `R` 행과 새 경로로 맞춘다.
  - `--ignore-submodules=dirty`: status와 같은 값이다. 이 옵션이 없으면 `git diff`가 서브모듈마다 `git status --porcelain=2 -uno`를 그 서브모듈 안에서 실행한다(`GIT_TRACE`로 확인). 서브모듈의 설정은 검사하지 않았으므로 그 실행을 막는다. 있으면 자식 프로세스가 없다(확인).
  - index를 쓰지 않는다. stat만 바뀐 파일이 있어도 공통 인자 `-c diff.autoRefreshIndex=false`가 refresh를 막는다(§2.1). 인자 없이 실행하면 index를 고쳐 쓰고 `post-index-change` hook이 돈다(악성 픽스처 확인). numstat은 외부 diff와 textconv를 쓰지 않았지만(악성 픽스처 확인) diff 서브커맨드 규칙대로 `--no-ext-diff --no-textconv`를 붙인다.
  - 충돌 중인 경로는 unstaged 출력에 두 번 나온다(`0\t0` unmerged 레코드와 stage 2 대 워크트리 레코드, `--diff-filter=u`로도 둘째는 남음). staged 출력에는 `0\t0`으로 나온다. 충돌 행은 줄 수를 보여 주지 않으므로 파서가 status의 conflicted 경로를 받아 버린다. 그 밖의 중복은 파싱 실패다.
  - untracked 파일은 git diff에 나오지 않으므로 줄 수가 없다. 화면도 untracked 그룹에는 줄 수와 합계를 쓰지 않는다(screens.md S-02).
  - 캐시: `RepositoryService`가 워크트리별로 두고, 그 워크트리의 status를 다시 조회하면 버린다(overview.md §5). 화면은 로드가 끝날 때마다 다시 묻는다. status 글자가 같아도(이미 수정된 파일을 더 고침) 서비스가 status를 다시 조회했으면 새로 센다.
  - 사용자가 파일을 고르지 않아도 상세를 열면 워크트리 전체를 읽는다. index에서는 일반 파일인 경로가 워크트리에서 FIFO면 git이 읽기에서 멈춘다. 이 경우 15초 조회 타임아웃(§2.5)이 프로세스를 끝내고, 화면은 `Line counts unavailable`로 끝난다(#230 보안 검토, 잔여 위험). git clone으로는 이런 상태를 만들 수 없다. 저장소를 디렉터리나 압축 파일로 받은 경우에만 생긴다.
  - 서브모듈 안에서 실행되지 않는다는 것은 SEC-T4-05의 numstat 변형(`ConfigExecutionScenarioTests`)이 검증한다. 하드닝된 실행에서는 canary가 없다. 플래그만 뺀 실행에서는 서브모듈 자체의 filter가 실행된다.
- **status의 `--untracked-files=all`**은 큰 저장소에서 느릴 수 있다. PB-5 측정에서 기준을 넘으면 `normal`로 바꾸고 디렉터리 단위로 표시하는 방안을 검토한다.

---

## 4. FetchCommand

| case | 서브커맨드 인자 배열 | 작업 디렉터리 | 비고 | 위협 |
|---|---|---|---|---|
| `fetch(remote:)` | `["fetch", "--prune", "--no-recurse-submodules", "--progress", "--no-tags", "--upload-pack=git-upload-pack", "--refmap=", "--end-of-options", "<remote name>", "+refs/heads/*:refs/remotes/<remote name>/*"]` | 저장소 경로 | §2.3 인증 인자 뒤에 `-c fetch.pruneTags=false -c remote.<remote name>.pruneTags=false -c fetch.writeCommitGraph=false -c fetch.bundleURI= -c http.cookieFile= -c http.saveCookies=false -c credential.protectProtocol=true -c credential.sanitizePrompt=true -c transfer.credentialsInUrl=die -c promisor.acceptFromServer=none`. 타임아웃 120초 | T2, T5, T6, T8, T11, T12, T13 |

- 원격마다 따로 실행한다 (`--all`을 쓰지 않음). 원격별로 인증 실패를 구분해 보여 주려는 것이다. 참고로 `--all`도 `--upload-pack`을 원격별 하위 fetch에 전달하는 것은 확인했다.
- `--upload-pack=git-upload-pack`은 로컬 `remote.<n>.uploadpack`을 무력화한다. `-c remote.<n>.uploadpack=`로는 무력화되지 않는다 (확인).
- **쓰는 범위를 명령줄에 고정한다(#209).** 앱의 fetch가 쓰는 ref는 `refs/remotes/<remote name>/*`뿐이다. 앱이 허용하는 쓰기는 이것과 `FETCH_HEAD`, 객체뿐이다. 저장소 설정으로는 이 범위를 넓힐 수 없다.
  - 고정하지 않으면 저장소 설정이 범위를 넓힌다(Apple Git 2.54.0 확인, security-review.md E40). 로컬 `remote.<n>.fetch=+refs/heads/*:refs/heads/*`가 있고 HEAD가 detached면 fetch가 로컬 전용 브랜치를 지우고 `main`을 강제로 되돌린다. 로컬 `fetch.pruneTags`·`remote.<n>.pruneTags`는 `--prune`과 함께 로컬 태그를 지운다.
  - refspec `+refs/heads/*:refs/remotes/<remote name>/*`를 명령줄에 준다. `--refmap=`(빈 값)은 설정된 refspec으로 원격 추적 ref를 덤으로 갱신하는 동작을 끈다.
  - `--prune`은 명령줄 refspec의 대상(`refs/remotes/<remote name>/*`) 안에서만 지운다.
  - `--no-tags`: 태그를 가져오지 않는다. 로컬 `remote.<n>.tagOpt=--tags`도 덮는다. 그래서 원격에만 있는 새 태그는 v0.1에서 보이지 않는다. 태그 자동 추적을 켜면 새 태그가 `refs/tags/*`에 생긴다. 기존 태그를 바꾸거나 지우지는 않지만, "원격 추적 ref만 쓴다"는 원칙을 깨므로 끈다.
  - fetch 전용 `-c`(`FetchCommand.configurationOverrides()`, 인자 순서 `[common] [neutralization] [fetch auth] [fetch overrides] fetch …`의 네 번째). 인증 인자 뒤에 두므로 로컬 값을 이긴다.
    - `-c fetch.pruneTags=false -c remote.<remote name>.pruneTags=false`: 이중 방어.
    - `-c fetch.writeCommitGraph=false`: fetch 뒤 commit-graph 파일 쓰기를 끈다.
    - `-c fetch.bundleURI=`: 로컬 `fetch.bundleURI`(git 2.40+, #99 호환성 매트릭스에서 2.39.5·2.40.4로 확인)가 있으면 fetch가 그 URI(원격이 아닌 임의 위치)에서 bundle을 받아 `refs/bundles/*`를 쓴다. bundle list가 `creationToken`을 쓰면 `.git/config`에 `fetch.bundleCreationToken`까지 기록한다(#210 보안 검토, 확인). 빈 값이면 꺼진다. 2.40 미만 git은 이 키를 무시한다.
    - `-c http.cookieFile= -c http.saveCookies=false`: generic 키의 쿠키 파일 읽기와 저장을 끈다(저장소 값과 사용자 값 모두). 저장소의 URL별 키는 §2.3이 같은 키로 끈다. 사용자(신뢰 scope)의 URL별 키는 그대로 둔다(#355).
    - `-c credential.protectProtocol=true -c credential.sanitizePrompt=true`: git의 자격 증명 CVE 수정(CVE-2024-52006, CVE-2024-50349)을 저장소가 끄지 못하게 한다. URL별 키는 §2.3이 같은 키로 켠다(#356).
    - `-c transfer.credentialsInUrl=die`: URL에 비밀번호가 있으면 접속 전에 실패한다(2.37+). 그 미만 git은 키를 무시하므로 `RepoConfigInspector.remotesWithPassword`가 그 원격을 미리 거부한다(#356).
    - `-c promisor.acceptFromServer=none`: 서버가 광고하는 promisor 원격을 받지 않는다(2.49+, #356).
  - `RepoConfigInspector`는 로컬 `remote.<n>.fetch`(대상이 `refs/remotes/<n>/` 밖), `fetch.pruneTags`, `remote.<n>.pruneTags`, `remote.<n>.tagOpt`, `fetch.bundleURI`, `remote.<n>.mirror`를 보고한다(SEC-T13-04).
  - 남는 한계: 설정 파일을 직접 고치면 원격 `a`와 `a/b`를 함께 둘 수 있다. 이때 `a`를 fetch하면 `--prune`이 `refs/remotes/a/b/*`를 지운다. 고정 전에도 같았고 피해는 `refs/remotes` 안으로 한정되며 다시 fetch하면 복구된다(#210 보안 검토).
- `--progress`의 stderr 진행 메시지(`Receiving objects:  45% (...)`)는 `LC_ALL=C`에서 영어로 고정된다. git이 실행되는 동안 `FetchProgressParser`가 읽어 진행률로 쓰고, 파싱에 실패하면 무시한다([parsing-spec.md §11.4](parsing-spec.md)). `remote:` 줄은 서버가 쓰므로 단계와 숫자만 꺼내고 문자열은 넘기지 않는다.
- 실행 방식(`GitClient.fetch`, #76): 저장소당 하나씩(`Repository.id` 기준) 요청 순서대로, 앱 전체에서 동시에 최대 2개. 조회 슬롯(4개)과 따로 센다. Task를 취소하면 프로세스 그룹을 종료하고(SIGTERM → 2초 → SIGKILL) `GitError.cancelled`, 120초가 지나면 `GitError.timeout`을 던진다.
- 원격 이름은 `configList`에서 얻은 값만 쓴다. `[A-Za-z0-9._/-]{1,100}` 형식이고 `-`로 시작하지 않아야 한다.
- **내장 전송 형태의 원격만 fetch한다(#350).** `RepoConfigInspector`가 원격마다 형태를 검사하고, `GitClient.fetch`는 검사를 통과한 원격(`RepoSafetyContext.fetchableRemotes`)이 아니면 git을 실행하기 전에 `configInspectionFailed`로 거부한다. 검사에서 빠진 원격(`remote.<n>.url`이 없거나 `maximumCheckedRemotes`를 넘은 것)도 거부한다.
  - 내장 형태: `https`·`http`·`ssh`·`git`·`file`·`git+ssh`·`ssh+git`의 `<scheme>://`(git처럼 대소문자 구분), scp 형식 주소, 경로(`TransportName.isBuiltInFetchForm`, git의 transport.c와 같은 규칙으로 바이트 단위 비교).
  - 거부: `<이름>::<주소>` 형식 전부(빈 이름 포함), 그 밖의 scheme, `ftp(s)`, 어느 scope든 `remote.<n>.vcs`(빈 값 포함), `url.<base>.insteadOf`로 바꾸면 내장 형태가 아닌 URL, 빈 URL 값(새 git에서는 URL 목록을 비우고, 그러면 git이 이 검사가 보지 않는 레거시 원격 파일을 읽는다). 원격의 URL 값은 첫 값만이 아니라 전부 검사하고, 바꾸기 규칙은 git이 고르는 가장 긴 것만이 아니라 맞는 것 전부를 검사한다(더 많이 거부할 뿐이다). 값 없는 `insteadOf` 키는 빈 접두사로 보고 모든 URL에 맞춘다.
  - 바이트로 비교한다. 설정 목록은 잘못된 UTF-8을 대체 문자로 바꿔 읽으므로, 대체 문자가 든 URL은 거부하고 대체 문자가 든 바꾸기 규칙이 있으면 모든 원격을 거부한다.
  - 상한(T15): 설정 순서로 처음 `maximumCheckedRemotes`(32)개 원격만 검사한다(한 번의 Fetch가 가져가는 16개보다 많다). URL이 `maximumURLsPerRemote`(4)개를 넘거나 `maximumCheckedLength`(1,024바이트)보다 긴 원격, 검사하지 않은 원격은 fetch하지 않는다. 바꾸기 규칙이 `maximumInsteadOfRewrites`(256)개를 넘거나 base·접두사가 1,024바이트보다 길면 모든 원격을 fetch하지 않는다. 조회는 계속한다.
  - `GIT_ALLOW_PROTOCOL`(§2.4)과 공통 인자(§2.1)가 그 아래 층으로 남는다.

---

## 5. GHCommand (gh allowlist)

공통 규칙 (ADR-0004):

- 실행 파일은 `/opt/homebrew/bin/gh`, `/usr/local/bin/gh` 순서로 찾는다.
- 작업 디렉터리는 **저장소 밖**의 중립 디렉터리다. 앱 전용 임시 디렉터리(`<사용자 임시 디렉터리>/io.github.kkdy21.overgrove.gh-neutral`, 모드 `0700`, 처음 쓸 때 만듦)를 쓴다. `gh`가 내부적으로 실행하는 git이 저장소 설정을 읽지 않게 하려는 것이다.
- `--repo OWNER/NAME`을 항상 명시한다. OWNER는 `[A-Za-z0-9-]{1,39}`이고 `-`로 시작하지 않는다. NAME은 `[A-Za-z0-9._-]{1,100}`이다.
- 환경 변수 allowlist는 다음과 같다. `GH_TOKEN`, `GITHUB_TOKEN`, `GH_HOST`, `GH_REPO`, `GH_ENTERPRISE_TOKEN`, `GH_CONFIG_DIR`, `BROWSER`, `GH_BROWSER`, `EDITOR`는 전달하지 않는다.

  ```
  HOME, USER, TMPDIR, PATH(§2.4와 같음),
  GH_PROMPT_DISABLED=1, GH_NO_UPDATE_NOTIFIER=1, GH_NO_EXTENSION_UPDATE_NOTIFIER=1,
  GH_TELEMETRY=0, DO_NOT_TRACK=1, GH_SPINNER_DISABLED=1, NO_COLOR=1, GH_PAGER=cat,
  LC_ALL=C, GIT_TERMINAL_PROMPT=0
  ```

| case | 인자 배열 | 파서 → 모델 | 비고 |
|---|---|---|---|
| `version` | `["--version"]` | 첫 줄 `gh version X.Y.Z (...)` | 온보딩 표시 |
| `authStatus` | `["auth", "status", "--hostname", "github.com", "--json", "hosts"]` | `GHAuthParser` → `GHAuthStatus` | `--json`이면 인증 문제가 있어도 종료 코드가 0이다 (gh 2.95 도움말). 판단은 `hosts["github.com"][].state == "success"`와 `active == true`로 한다. 필드: `active, gitProtocol, host, login, scopes, state, tokenSource`. `--show-token` 금지 |
| `issueList(repo:)` | `["issue", "list", "--repo", "<OWNER/NAME>", "--state", "open", "--limit", "200", "--json", "number,title,state,labels,assignees,updatedAt,url"]` | `IssueParser` → `[Issue]` | 닫힌 이슈는 v0.1.0 범위 밖 |

실행과 결과 처리 (`Overgrove/GitHub/GHClient`, #80):

- 실행 파일은 위 두 경로를 순서대로 보고, 실행 가능한 일반 파일(심볼릭 링크는 따라감)인 첫 경로를 쓴다. 호출할 때마다 다시 찾으므로 앱 실행 중에 gh를 설치해도 반영된다. 둘 다 없으면 `authStatus()`는 `GHAuthStatus.notInstalled`를 돌려주고, 그 밖의 명령은 `GHError.notInstalled`를 던진다.
- 작업 디렉터리는 위의 앱 전용 중립 디렉터리다. 비어 있고 저장소가 아니다. 만들지 못하면 실행이 `launchFailed`로 실패한다.
- 원본 출력은 `GHClient` 밖으로 나가지 않는다. 호출자는 파싱된 값(`GHAuthStatus`, `[Issue]`, 버전 첫 줄)만 받는다.
- 실행 제한은 §2.5의 gh 값이다. 타임아웃과 stdout 잘림은 종료 코드와 관계없이 실패(`timeout`, `outputTruncated`)로 본다. 잘린 JSON은 해석하지 않는다.
- `authStatus`: 판단은 JSON으로만 한다. JSON이 아니면 종료 코드 4는 `GHAuthStatus.notLoggedIn`, 그 밖의 0이 아닌 코드는 `nonZeroExit`(예: `--json`을 모르는 옛 gh의 `unknown flag: --json`), 0은 `parseFailed`다.
- 그 밖의 명령은 종료 코드 0만 성공이다. 종료 코드 4(gh의 "인증 필요")는 `GHError.notLoggedIn`, 나머지는 마스킹한 stderr를 담은 `nonZeroExit`다.
- 에러 타입은 `GitError`와 따로 둔 `GHError`다. gh 문제는 이슈 패널만 끄기 때문이다 (ADR-0004 §4). 사용자에게는 `gh auth login`, `brew install gh`를 복사 가능한 명령으로만 보여 준다.
- `XDG_CONFIG_HOME`도 전달하지 않는다. gh는 `~/.config/gh`의 설정을 읽는다. 셸에서만 `XDG_CONFIG_HOME`이나 `GH_CONFIG_DIR`을 바꿔 쓰는 사용자는 앱에서 로그인하지 않은 것으로 보인다 (의도된 동작, T10 잔여 위험과 같음).

GitHub 원격 판별: `configList`의 원격 URL이 다음 중 하나와 맞을 때만 `OWNER/NAME`을 뽑는다. 그 밖의 호스트는 이슈 패널을 끄고 "github.com 원격 없음"을 보여 준다.

- `https://github.com/OWNER/NAME(.git)?`
- `git@github.com:OWNER/NAME(.git)?`
- `ssh://git@github.com/OWNER/NAME(.git)?`

여러 원격이 맞으면 gh와 같은 순서로 고른다: `upstream`, `github`, `origin`, 그다음 설정 순서. fork에서는 이슈가 `upstream`에 있기 때문이다. 판별은 검증된 목록(`RepoConfigInspector` 검사를 거친 조회)의 원격으로만 하고, 캐시에서 먼저 그린 목록으로는 gh를 실행하지 않는다 (`GitHubRemote`, #81).

---

## 6. stderr 분류 패턴

`LC_ALL=C` 기준이다. 대소문자를 구분하지 않고 부분 일치로 찾는다. 검사는 마스킹한 stderr에 한다.

- **`remote:`로 시작하는 줄은 보지 않는다(#78).** HTTP 전송에서 서버가 쓴 글은 `remote:` 줄로 온다. 서버가 분류를 고르거나, 다른 분류로 실제 오류를 가리지 못하게 하려는 것이다. 로컬 git과 ssh가 쓴 줄만 본다.
- ssh 전송에서는 서버의 stderr가 접두사 없이 그대로 온다. 그래서 악성 ssh 서버는 분류를 고를 수 있다. 다만 화면 문구는 모두 앱이 쓴 것이고(`FetchFailureGuidance`), 서버가 쓴 글은 마스킹한 Details에만 나온다. 이 위험은 받아들인다.
- 아래 표의 순서대로 검사한다. 더 구체적인 원인이 이긴다. 바뀐 호스트 키 경고는 맨 먼저 본다. 로컬 ssh만 찍는 배너라서, ssh가 경고 뒤에도 연결을 이어 가게 설정된 경우 서버가 다른 분류 문구를 써서 경고를 가리지 못하게 하려는 것이다(#200 보안 검토).

| 분류 (GitError) | 패턴 |
|---|---|
| `hostKeyVerificationFailed(changed: true)` | `REMOTE HOST IDENTIFICATION HAS CHANGED` (OpenSSH 경고 배너) |
| `dubiousOwnership` | `detected dubious ownership` |
| `partialCloneObjectMissing` | `lazy fetching disabled`, `from promisor remote`. 또는 git 자신의 전송 거부 줄(`fatal: transport '<이름>' not allowed`)과 정확한 `fatal: unable to read <40·64자리 object ID>` 줄이 함께 있을 때. 전송 거부보다 먼저 본다: 막힌 lazy fetch는 `transport 'file' not allowed`도 함께 내고, `GIT_NO_LAZY_FETCH`가 없는 git(예: 2.36)은 그 뒤에 `unable to read <oid>`만 낸다. 조회는 전송을 쓰지 않고 거부된 fetch는 객체를 읽지 않으므로, 이 조합은 누락 객체다 (#212, #303) |
| `transportNotAllowed(transport)` | `fatal: transport '<이름>' not allowed`로 **시작하는 줄** (`GIT_ALLOW_PROTOCOL` 밖의 전송, `ext`, `fd`). `remote:` 줄은 인정하지 않는다. 이름은 `[A-Za-z0-9][A-Za-z0-9+.-]*`이고 64자 이하일 때만 메시지에 넣는다 |
| `hostKeyVerificationFailed(changed: false)` | `Host key verification failed` |
| `sshAuthenticationFailed` | `Permission denied (` + OpenSSH 방식 이름(`publickey`, `password`, `keyboard-interactive`, `hostbased`, `gssapi`). 방식 목록이 없는 로컬 파일 오류(`Permission denied`)는 해당하지 않는다 |
| `authenticationFailed` | `Authentication failed`, `could not read Username`, `could not read Password`, `terminal prompts disabled`, `Invalid username or password`, `returned error: 401` |
| `accessDenied` | `returned error: 403` |
| `remoteNotFound` | `returned error: 404`, `does not appear to be a git repository`, `fatal: repository '…' not found` 줄 |
| `networkUnavailable` | `Could not resolve host`(ssh의 `Could not resolve hostname` 포함), `unable to look up`, `Connection refused`, `Connection timed out`, `Operation timed out`, `Network is unreachable`, `No route to host`, `Failed to connect to`, `Couldn't connect to server`, `Connection reset by peer` |
| `notARepository` | `not a git repository` |
| `noMergeBase` | `fatal: no merge base found`와 **똑같은 줄** (#157). 다른 메시지 안의 같은 문구(파일·ref 이름)는 인정하지 않는다 |
| `configInspectionFailed` | (설정 검사 단계의 비정상 종료나 파싱 실패) |

`dubiousOwnership`이면 메시지에 "앱은 `safe.directory`를 우회하지 않는다"는 안내를 붙인다.

예시 문자열은 Apple Git 2.54.0에서 로컬 HTTP 서버(401/403/404/500), 없는 로컬 경로, 닫힌 로컬 포트로 채집했다(`GitErrorTests`). DNS 실패와 경로 없음 문구는 네트워크가 필요해 OpenSSH 문구를 그대로 썼다.

---

## 7. 타입으로 만들지 않는 명령

다음은 1차 범위에서 **어떤 형태로도 실행하지 않는다**. 코드 리뷰와 `security-reviewer` 에이전트가 이 목록을 기준으로 검사한다.

`push`, `pull`, `merge`, `rebase`, `reset`, `restore`, `checkout`, `switch`, `clean`, `commit`, `cherry-pick`, `revert`, `am`, `apply`, `stash push/save/apply/pop/drop/clear/branch`, `branch -d/-D/-m`, `tag -d`, `worktree add/remove/move/prune/lock/unlock/repair`, `gc`, `maintenance`, `prune`, `update-ref`, `update-index`, `config --add/--unset/--replace-all/(쓰기 형태)`, `remote add/remove/set-url`, `submodule *`, `lfs *`, `gh issue create/edit/close`, `gh pr *`, `gh auth login/logout/refresh/setup-git`, `gh api`, `gh repo *`.

`config`는 `--list --show-scope -z --includes` 조합만 허용한다.
