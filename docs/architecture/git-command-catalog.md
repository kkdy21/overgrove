# git·gh 명령 카탈로그

> 상태: Proposed (Phase 2 승인 대기) · 관련: ADR-0004, ADR-0008, ADR-0009, ADR-0010, ADR-0011, [overview.md](overview.md), [parsing-spec.md](parsing-spec.md), [../design/security-review.md](../design/security-review.md)

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

## 2. 공통 인자와 환경

### 2.1 공통 보안 인자 (모든 git 호출)

| 인자 | 목적 | 위협 |
|---|---|---|
| `--no-pager` | 페이저 실행 방지 | T10 |
| `--no-optional-locks` | 조회 중 `index.lock`을 잡지 않음, index 갱신 쓰기 방지 | T13 |
| `--literal-pathspecs` | `:(exclude)`, glob 등 pathspec 매직을 끔 | T9 |
| `-c core.fsmonitor=false` | fsmonitor 훅 실행 방지. 서브프로세스(서브모듈)에도 전파됨 (확인) | T1 |
| `-c core.hooksPath=/dev/null` | 모든 훅 실행 방지 (fetch의 `reference-transaction` 포함, 확인) | T2 |
| `-c core.askPass=` | 로컬 `core.askPass` 실행 방지 (확인) | T12 |
| `-c protocol.ext.allow=never` | `ext::` 원격과 `insteadOf`로 바꿔치기한 `ext::` 차단 (확인) | T5 |
| `-c protocol.fd.allow=never` | `fd::` 원격 차단. 기본값에서는 허용되고 정지를 일으킴 (확인) | T5, T15 |
| `-c core.alternateRefsCommand=` | `objects/info/alternates`가 있는 저장소를 fetch할 때 로컬 `core.alternateRefsCommand`가 실행되는 것을 막음. 빈 값으로 덮어도 fetch는 성공 (확인: [fixtures.md §8](../testing/fixtures.md)) | T5 |
| `-c log.showSignature=false` | 로컬 `log.showSignature=true`로 인한 `gpg.program` 실행 방지 (확인) | T7 |
| `-c gc.auto=0` | 자동 gc 방지 | T8 |
| `-c maintenance.auto=false` | fetch 뒤 `git maintenance run --auto` 실행 방지 (확인) | T8 |
| `-c color.ui=never` | 출력에 ANSI 코드가 섞이지 않게 함 | 파싱 안정성 |

diff를 만드는 서브커맨드(`diff`, `diff-tree`, `stash show`, `log -p`)에는 서브커맨드 인자로 `--no-ext-diff --no-textconv`를 반드시 붙인다 (T3). `git diff`는 기본으로 외부 diff 드라이버를 실행한다 (확인).

### 2.2 동적 무력화 인자 (RepoConfigInspector, ADR-0009)

신뢰하지 않는 scope(`local`, `worktree`)에서 `filter.<d>.*`를 찾으면, 드라이버마다 다음 인자를 모든 호출에 붙인다.

```
-c filter.<d>.clean= -c filter.<d>.smudge= -c filter.<d>.process= -c filter.<d>.required=false
```

- 빈 clean 명령은 필터를 끈다.
- `required=true`인 상태에서 clean만 비우면 `fatal: clean filter failed`가 난다. 그래서 `required=false`도 함께 넣는다 (확인).
- `<d>` 드라이버 이름은 `[A-Za-z0-9._-]{1,64}`만 허용한다. 이 형식에 맞지 않는 이름이 있으면 무력화 인자를 만들 수 없다. 이때는 `configInspectionFailed`로 조회를 막는다 (fail closed).

### 2.3 fetch 전용 인증 인자

```
-c credential.helper=
  [신뢰 scope의 credential.*helper 항목을 원래 순서와 키 그대로 재삽입]
[신뢰하지 않는 scope에서 false로 설정된 http.sslVerify, http.<url>.sslVerify 키마다: -c <같은 키>=true]
```

- 재삽입 예: Apple Git 내장 설정(`unknown` scope)의 `credential.helper=osxkeychain`, `gh auth setup-git`이 global에 쓴 `credential.https://github.com.helper=`(빈 값)와 `credential.https://github.com.helper=!/opt/homebrew/bin/gh auth git-credential`.
- generic 키 초기화(`credential.helper=`)는 그 이전에 읽힌 URL별 helper까지 비운다 (확인). 그래서 신뢰 항목은 반드시 초기화 **뒤에** 다시 넣는다.
- `http.<url>.sslVerify`는 URL별 키가 generic 키보다 우선한다. 그래서 같은 URL 키로 덮어써야 한다 (확인: `config --get-urlmatch`).

### 2.4 환경 변수 (allowlist, 부모 환경 미상속)

| 변수 | 값 | 대상 |
|---|---|---|
| `LC_ALL`, `LANG` | `C` | 모든 git |
| `GIT_TERMINAL_PROMPT` | `0` | 모든 git |
| `GIT_OPTIONAL_LOCKS` | `0` | 모든 git (`--no-optional-locks`와 중복 방어) |
| `GIT_PAGER`, `PAGER` | `cat` | 모든 git |
| `GIT_ASKPASS`, `SSH_ASKPASS` | 빈 문자열 | 모든 git (빈 `GIT_ASKPASS`는 `core.askPass`보다 우선해 실행을 막음, 확인) |
| `GIT_PROXY_COMMAND` | 빈 문자열 | 모든 git (로컬 `core.gitProxy` 무력화, 확인) |
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
| `probeRepository` | `["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir", "--is-bare-repository"]` | 등록 경로 | 줄 단위 → `Repository` | T14 |
| `configList` | `["config", "--list", "--show-scope", "-z", "--includes"]` | 저장소 경로 | `ConfigParser` → 보안 보고서, 원격 목록 | T4–T8 |
| `worktreeList` | `["worktree", "list", "--porcelain", "-z"]` | 저장소 경로 | `WorktreeParser` → `[Worktree]` | — |
| `status` | `["status", "--porcelain=v2", "-z", "--branch", "--show-stash", "--untracked-files=all", "--ignore-submodules=dirty"]` | 워크트리 경로 | `StatusParser` → `WorkingState`, `UpstreamStatus` | T1, T4 |
| `refs` | `["for-each-ref", "--format=%(refname)%00%(objectname)%00%(*objectname)%00%(upstream)%00%(HEAD)%00%(committerdate:unix)%00%(symref)", "refs/heads", "refs/remotes", "refs/tags"]` | 저장소 경로 | `RefParser` → `[Branch]` | — |
| `aheadBehind(local:upstream:)` | `["rev-list", "--left-right", "--count", "--end-of-options", "<upstream full ref>...<local full ref>"]` | 저장소 경로 | `RevListParser` → (behind, ahead) | T9 |
| `stashList` | `["stash", "list", "-z", "--format=%gd%x00%H%x00%gs%x00%ct"]` | 저장소 경로 | `StashParser` → `[Stash]` | — |
| `stashFiles(oid:)` | `["stash", "show", "--include-untracked", "--numstat", "-z", "--no-ext-diff", "--no-textconv", "--end-of-options", "<oid>"]` | 저장소 경로 | `NumstatParser` → `StashDetail` | T3, T9 |
| `stashPatch(oid:path:)` | `["stash", "show", "-p", "--include-untracked", "--no-ext-diff", "--no-textconv", "--end-of-options", "<oid>", "--", "<path>"]` | 저장소 경로 | 원문 패치 → S-10 | T3, T9 |
| `graphPage(skip:limit:)` | `["log", "--exclude=refs/stash", "--all", "--date-order", "-z", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s", "--skip=<n>", "-n", "<limit>"]` | 저장소 경로 | `LogParser` → `[CommitNode]` → GraphEngine | T7 |
| `commitMeta(oid:)` | `["log", "-1", "-z", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%ce%x00%ct%x00%B", "--end-of-options", "<oid>"]` | 저장소 경로 | `LogParser` → `CommitDetail` | T7, T9 |
| `commitFiles(oid:)` | 루트·일반 커밋: `["diff-tree", "-r", "-z", "--raw", "--numstat", "-M", "--no-ext-diff", "--no-textconv", "--no-commit-id", "--root", "--end-of-options", "<oid>"]`<br>병합 커밋: `[..., "--end-of-options", "<first parent oid>", "<oid>"]` | 저장소 경로 | `NumstatParser`(raw+numstat) → `CommitDetail.files` | T3, T9 |
| `commitPatch(oid:parent:path:)` | `["diff-tree", "-p", "-M", "--no-ext-diff", "--no-textconv", "--root", "--end-of-options", "<parent oid 또는 생략>", "<oid>", "--", "<path>"]` | 저장소 경로 | 원문 패치 → S-10 | T3, T9 |
| `worktreeDiff(path:staged:)` | `["diff", "--no-ext-diff", "--no-textconv", "-M", (staged ? "--cached" : 생략), "--", "<path>"]` | 워크트리 경로 | 원문 패치 → S-10 | T3, T9 |
| `untrackedPreview(path:)` | `["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--", "/dev/null", "<path>"]` (종료 코드 1이 정상) | 워크트리 경로 | 원문 패치 → S-10 | T3, T14 |
| `fileHistory(path:limit:)` | `["log", "--follow", "-z", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s", "-n", "<limit>", "--", "<path>"]` | 워크트리 경로 | `LogParser` → `[FileHistoryEntry]` | T7, T9 |

보충 규칙:

- **원격 이름과 URL**은 `configList` 결과의 `remote.<name>.url`에서 얻는다. 별도 명령을 쓰지 않는다. URL은 표시 전에 `CredentialMasker`를 거친다.
- **ahead/behind**는 워크트리마다 `status`의 `# branch.ab +A -B` 헤더에서 얻는다. 체크아웃되지 않은 로컬 브랜치(사이드바 LOCAL)만 `aheadBehind`를 필요할 때 실행한다. `rev-list` 출력은 `<behind>\t<ahead>`다 (확인).
- **그래프 페이지**는 `--skip`과 `-n`으로 나눈다. 같은 ref 집합이면 순서가 결정적이라 GraphEngine이 열린 레인 상태를 이어서 계산한다. ref 집합 해시가 바뀌면 처음부터 다시 계산한다. 10만 커밋에서 뒤쪽 페이지의 `--skip` 비용이 PB-4를 넘으면, 스트리밍 읽기 모드(한 프로세스의 출력을 페이지 단위로 소비)로 바꾼다. 이 결정은 Phase 3 성능 측정 뒤에 ADR-0010을 갱신해 남긴다.
- **untrackedPreview**는 `PathValidator`가 경로를 해석한 결과가 워크트리 안에 있을 때만 실행한다. 심볼릭 링크는 내용 대신 링크 대상 문자열만 보여 준다 (T14).
- **status의 `--untracked-files=all`**은 큰 저장소에서 느릴 수 있다. PB-5 측정에서 기준을 넘으면 `normal`로 바꾸고 디렉터리 단위로 표시하는 방안을 검토한다.

---

## 4. FetchCommand

| case | 서브커맨드 인자 배열 | 작업 디렉터리 | 비고 | 위협 |
|---|---|---|---|---|
| `fetch(remote:)` | `["fetch", "--prune", "--no-recurse-submodules", "--progress", "--upload-pack=git-upload-pack", "--end-of-options", "<remote name>"]` | 저장소 경로 | §2.3 인증 인자 포함. 타임아웃 120초 | T2, T5, T6, T8, T11, T12 |

- 원격마다 따로 실행한다 (`--all`을 쓰지 않음). 원격별로 인증 실패를 구분해 보여 주려는 것이다. 참고로 `--all`도 `--upload-pack`을 원격별 하위 fetch에 전달하는 것은 확인했다.
- `--upload-pack=git-upload-pack`은 로컬 `remote.<n>.uploadpack`을 무력화한다. `-c remote.<n>.uploadpack=`로는 무력화되지 않는다 (확인).
- `--prune`은 원격 추적 ref(`refs/remotes/*`)만 지운다. 로컬 브랜치와 태그는 건드리지 않는다. 앱이 허용하는 쓰기는 이것뿐이다.
- `--progress`의 stderr 진행 메시지(`Receiving objects:  45% (...)`)는 `LC_ALL=C`에서 영어로 고정된다. 진행률 표시에 쓰고, 파싱에 실패하면 무시한다.
- 원격 이름은 `configList`에서 얻은 값만 쓴다. `[A-Za-z0-9._/-]{1,100}` 형식이고 `-`로 시작하지 않아야 한다.

---

## 5. GHCommand (gh allowlist)

공통 규칙 (ADR-0004):

- 실행 파일은 `/opt/homebrew/bin/gh`, `/usr/local/bin/gh` 순서로 찾는다.
- 작업 디렉터리는 **저장소 밖**의 중립 디렉터리다. 앱 전용 임시 디렉터리를 쓴다. `gh`가 내부적으로 실행하는 git이 저장소 설정을 읽지 않게 하려는 것이다.
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

GitHub 원격 판별: `configList`의 원격 URL이 다음 중 하나와 맞을 때만 `OWNER/NAME`을 뽑는다. 그 밖의 호스트는 이슈 패널을 끄고 "github.com 원격 없음"을 보여 준다.

- `https://github.com/OWNER/NAME(.git)?`
- `git@github.com:OWNER/NAME(.git)?`
- `ssh://git@github.com/OWNER/NAME(.git)?`

---

## 6. stderr 분류 패턴

`LC_ALL=C` 기준이다. 대소문자를 구분하지 않고 부분 일치로 찾는다. 검사는 마스킹한 stderr에 한다.

| 분류 (GitError) | 패턴 |
|---|---|
| `authenticationFailed` | `Authentication failed`, `could not read Username`, `could not read Password`, `terminal prompts disabled`, `Permission denied (publickey`, `Host key verification failed`, `Invalid username or password` |
| `networkUnavailable` | `Could not resolve host`, `unable to look up`, `Connection refused`, `Connection timed out`, `Operation timed out`, `Network is unreachable` |
| `notARepository` | `not a git repository` |
| `dubiousOwnership` | `detected dubious ownership` |
| `blockedBySecurityPolicy` | `transport 'ext' not allowed`, `transport 'fd' not allowed` |
| `configInspectionFailed` | (설정 검사 단계의 비정상 종료나 파싱 실패) |

`dubiousOwnership`이면 메시지에 "앱은 `safe.directory`를 우회하지 않는다"는 안내를 붙인다.

---

## 7. 타입으로 만들지 않는 명령

다음은 1차 범위에서 **어떤 형태로도 실행하지 않는다**. 코드 리뷰와 `security-reviewer` 에이전트가 이 목록을 기준으로 검사한다.

`push`, `pull`, `merge`, `rebase`, `reset`, `restore`, `checkout`, `switch`, `clean`, `commit`, `cherry-pick`, `revert`, `am`, `apply`, `stash push/save/apply/pop/drop/clear/branch`, `branch -d/-D/-m`, `tag -d`, `worktree add/remove/move/prune/lock/unlock/repair`, `gc`, `maintenance`, `prune`, `update-ref`, `update-index`, `config --add/--unset/--replace-all/(쓰기 형태)`, `remote add/remove/set-url`, `submodule *`, `lfs *`, `gh issue create/edit/close`, `gh pr *`, `gh auth login/logout/refresh/setup-git`, `gh api`, `gh repo *`.

`config`는 `--list --show-scope -z --includes` 조합만 허용한다.
