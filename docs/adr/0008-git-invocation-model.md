# ADR-0008: git 호출 모델 — Process, 인자 배열, 환경 allowlist, 타임아웃, 출력 상한

> 상태: Accepted · 날짜: 2026-11-05 · 관련: N5, T1–T3, T9–T13, T15, [architecture/git-command-catalog.md](../architecture/git-command-catalog.md), [design/security-review.md](../design/security-review.md)

## 맥락

자체 Git 엔진을 만들지 않고(N5) 시스템 `git`을 호출한다. 이 앱이 신뢰할 수 없는 저장소에 대해 `git`을 실행한다는 점이 보안 위협의 대부분을 만든다. 호출 방식을 한 곳에서 통제해야 위협 대응을 증명할 수 있다. 세부 규칙은 Phase 2 보안 검토에서 실험으로 확인했다 ([security-review.md](../design/security-review.md) §4).

## 결정

### 1. 단일 경로

- `Process`는 `Overgrove/Execution/ProcessRunner`에서만 만든다.
- git은 `Overgrove/Git/GitClient`(actor), gh는 `Overgrove/GitHub/GHClient`(actor)만 `ProcessRunner`를 호출한다.

### 2. 셸 금지

- `executableURL`에 실행 파일의 절대 경로를 넣고, 인자는 `[String]` 배열로 넘긴다.
- `/bin/sh -c`, `popen`, `system()`은 쓰지 않는다.

### 3. 실행 파일

| 대상 | 규칙 |
|---|---|
| git | 기본은 `/usr/bin/git`(Xcode·CLT git으로 연결되는 shim)이다. v0.2.0에서 사용자 지정 절대 경로를 허용한다. 지정 경로는 실행 가능 여부와 `git --version` 응답을 확인한 뒤에만 쓴다. |
| gh | `/opt/homebrew/bin/gh` → `/usr/local/bin/gh` 순서로 찾는다. PATH 검색을 하지 않는다. |
| 최소 git 버전 | **2.36** (`worktree list -z`). 시작할 때 `git --version`을 확인하고, 미달이면 온보딩에서 안내하고 조회를 막는다. |

### 4. 명령 allowlist

- 명령은 `ReadOnlyGitCommand`와 `FetchCommand` 열거형의 case로만 만든다. 열거형이 인자 배열을 직접 만든다.
- 임의 문자열 인자를 받는 생성자는 없다.
- 쓰기 명령(push, pull, reset, clean, checkout, commit, merge, rebase, stash apply/pop/drop, worktree add/remove/prune, branch -d 등)은 타입이 없다.

### 5. 공통 보안 인자

모든 git 호출 앞에 붙인다. 최종 목록은 [security-review.md §3.1](../design/security-review.md)에 있다.

```
--no-pager --no-optional-locks --literal-pathspecs
-c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.askPass=
-c protocol.ext.allow=never -c protocol.fd.allow=never
-c log.showSignature=false -c gc.auto=0 -c maintenance.auto=false -c color.ui=never
```

여기에 `RepoConfigInspector`가 만든 동적 무력화 인자(ADR-0009)를 덧붙인다. diff를 만드는 명령에는 `--no-ext-diff --no-textconv`를 붙인다.

### 6. 환경 변수

부모 환경을 상속하지 않고 allowlist로 새로 만든다.

- **고정값**: `LC_ALL=C`, `LANG=C`, `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`, `GIT_PAGER=cat`, `PAGER=cat`, `GIT_ASKPASS=`(빈 값), `SSH_ASKPASS=`(빈 값), `GIT_PROXY_COMMAND=`(빈 값), `GIT_SSH_COMMAND=<신뢰 범위의 core.sshCommand 또는 ssh -o BatchMode=yes>`
- **부모에서 그대로 전달**: `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SSH_AUTH_SOCK`
- **고정된 PATH**: `/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`. credential helper와 ssh를 찾는 데 쓴다.

### 7. 실행 제한

| 항목 | 값 |
|---|---|
| 타임아웃 | 기본 15초, fetch 120초 |
| 초과 시 종료 | SIGTERM → 2초 뒤 SIGKILL |
| 출력 상한 | stdout 10MB, stderr 64KB. 넘으면 읽기를 멈추고 `truncated` 플래그를 세운다 |
| 작업 디렉터리 | 대상 워크트리의 절대 경로. `-C`를 쓰지 않고 `currentDirectoryURL`을 쓴다 |
| 취소 | Swift Task 취소가 프로세스 종료로 이어진다 |

### 8. 인자 검증

- 커밋을 가리킬 때는 검증된 object ID(40 또는 64자리 소문자 hex)를 쓴다.
- ref를 가리킬 때는 `refs/`로 시작하는 정규화된 전체 이름만 쓴다. 짧은 이름을 인자로 넘기지 않는다.
- 경로는 `--` 뒤에 둔다. `--literal-pathspecs`로 pathspec 매직을 끈다.
- 리비전 인자 앞에는 `--end-of-options`를 둔다.

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| libgit2 | 프로세스 비용 없음 | N5 위반, 사용자 git 설정과 다르게 동작 | N5 |
| 셸 문자열 실행 | 구현이 쉬움 | 인젝션 | T9 |
| 부모 환경 상속 | 사용자 환경과 동일 | `GIT_DIR`, `GIT_SSH_COMMAND` 등 오염 | T10 |
| PATH 검색으로 git 찾기 | Homebrew git 자동 사용 | PATH 조작 위험, Finder 실행 시 PATH가 다름 | 예측 가능성 우선 |

## 결과

- 모든 git 실행을 한 지점에서 감사할 수 있다. 보안 테스트가 `GitClient`가 실제로 만드는 인자 배열을 검사하면 된다.
- 사용자의 셸 환경(예: `GIT_SSH_COMMAND`, 사용자 지정 PATH)을 쓰지 않는다. 사용자가 셸에서 쓰던 일부 git 동작이 앱에서는 다를 수 있다. 온보딩과 에러 메시지에서 설명한다.
- Apple Git 버전은 Xcode·CLT 버전을 따라간다. 이 맥 기준 2.50.1 (Apple Git-155).

## 후속 작업

- [ ] ProcessRunner(#41 ✓), GitEnvironment(#42 ✓), GitCommand·GitClient(#43) 구현
- [ ] 인자 배열 스냅샷 테스트 SEC-T9-xx, SEC-T10-xx
- [x] git 실행 파일: `xcode-select -p`(설치 대화상자를 띄우지 않음)로 활성 개발자 디렉터리를 얻고 `<dir>/usr/bin/git`을 한 번 확정해 직접 실행한다. `/usr/bin/git` shim의 호출당 약 8ms와, 개발 도구가 없을 때 뜨는 설치 대화상자를 피한다(`GitEnvironment.discover`, #42)
- [ ] v0.2.0: 사용자 지정 git 경로 설정
