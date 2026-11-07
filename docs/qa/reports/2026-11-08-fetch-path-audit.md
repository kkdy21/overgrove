# fetch 경로 끝에서 끝까지 점검 보고 (2026-11-08)

> 상태: 보고 · 관련: #353, #354, #355, #356, #317, #350, #161, ADR-0008, ADR-0009, [security-review.md](../../design/security-review.md) T1–T19, [git-command-catalog.md](../../architecture/git-command-catalog.md) §2.3·§4, [git 호환성 보고](2026-11-08-git-compatibility.md)

v0.1.0을 앞두고 fetch 경로에서 출시 전 결함이 연달아 나왔다(#317, #350). fetch는 앱에서 유일하게 전송을 여는 경로다. 그래서 이 경로를 처음 보는 사람의 눈으로 끝에서 끝까지 다시 점검했다. 코드를 고치는 작업이 아니라 점검과 보고다. 찾은 결함은 메인테이너에게 비공개로 먼저 알렸고, 이 문서에는 재현 절차 없이 이슈 번호만 적는다.

## 1. 요약

- **판정: 출시 전에 고칠 결함 2건(#354, #355)을 찾았고, 독립 점검에서 3건이 더 나왔다(#361, #356 범위 추가, #362, §7).** 그 밖에 저장소가 통제하는 설정으로 fetch 중 프로그램이 실행되는 경로는, 실측한 범위에서 모두 막혀 있었다.
  - **#354 (P0)**: 최신 git(2.54)의 설정형 hook(`hook.<name>.*`)이 fetch 중 실행된다. `core.hooksPath=/dev/null`은 hooks 디렉터리만 막는다. git 2.36.6에는 이 기능이 없다. fetch 실패 안내가 hook 검사 없이 터미널 명령을 제시하는 문제(관찰 4)도 #354에서 함께 고친다.
  - **#355 (P1)**: 저장소 로컬 프록시·쿠키 설정 일부가 fetch에서 중화되지 않는다. 세 git 모두 같다.
- **조회 경로는 hook을 일으키지 않는다.** 앱이 실행하는 조회 전부를 모든 hook 이벤트가 설정된 저장소에서 돌렸고, hook은 한 번도 실행되지 않았다(대조군: 같은 저장소의 평범한 `git commit`은 hook을 실행).
- **최신 git 설정 후보 4건**은 릴리스 노트와 설정 문서를 근거로 찾았다. 문서 근거만 있고, 실측과 조치는 #356에서 한다(§6).
- 막혀 있던 경로마다 "평범한 git에서는 실행된다"는 대조군을 함께 돌렸다. 대조군이 실행되지 않은 시나리오는 차단 근거로 세지 않았다(§4.3).

## 2. 범위와 방법

### 2.1 범위

`RepositoryService.fetch` → `RepoConfigInspector`(사전 검사) → `GitClient.fetch`(partial clone 게이트, 차단 사유, 인자 조립) → `GitEnvironment`(공통 인자, 환경 변수 allowlist) → `ProcessRunner`(실행, 시간 제한) → `GitError.classify`(오류 분류) → `FetchFailureGuidance`·`FetchController`·`FetchFailureDetailsView`(화면). 기준 커밋은 #350·#107 쪽 변경(#351)이 들어온 `main`이다.

범위 밖: gh 호출(T16), 저장소 등록, Terminal 열기 자체(T14). 다만 fetch 화면이 터미널 명령을 제시하는 부분은 포함했다.

### 2.2 방법

| 방법 | 내용 |
|---|---|
| 코드 따라가기 | 위 경로의 각 단계를 security-review.md T1–T19와 git-command-catalog.md에 대조했다 |
| 실측 하네스 | 앱과 같은 인자(`GitEnvironment.commonArguments`, inspector가 만드는 중화·fetch 인증 인자, `FetchCommand`의 overrides와 subcommand)와 같은 환경(`GitEnvironment.environment(allowsTransport:)`의 변수만, `env -i`)으로 git을 실행하는 셸 하네스를 만들었다. 하네스는 저장소에 넣지 않았다 |
| 대조군 | 같은 시나리오를 앱 인자 없이 평범한 `git fetch`로 돌려, 저장소 설정이 실제로 실행되는 시나리오인지 먼저 확인했다 |
| canary | 실행 여부는 무해한 파일 생성으로만 확인했다. 네트워크 시나리오는 로컬 HTTP 서버와 로컬 프록시(127.0.0.1)로 요청과 헤더만 기록했다 |
| 독립 점검 | security-reviewer 에이전트에게 결론을 알리지 않고 같은 범위를 점검시켰다(§7) |
| 릴리스 노트 | git 2.40.0–2.54.0(포인트 릴리스 포함) 릴리스 노트와 설정 문서에서 설정으로 실행·파일 접근·네트워크가 생기는 기능을 찾았다(§6) |

### 2.3 git

| 이름 | 버전 | 출처 |
|---|---|---|
| Apple Git | 2.54.0 (Apple Git-157) | Xcode 개발자 디렉터리의 `usr/bin/git`(앱이 쓰는 것) |
| Homebrew git | 2.54.0 | 설치되어 있던 것 |
| git 2.36.6 | 2.36.6 | kernel.org tarball(SHA-256 확인)을 로컬에서만 빌드. 방법은 [git 호환성 보고 §2.2](2026-11-08-git-compatibility.md)와 같다 |

장비는 Apple M1 Pro, macOS 26.6.2다.

## 3. 단계별 점검

| 단계 | 확인한 것 | 결과 |
|---|---|---|
| 사전 검사 | fetch마다 설정을 다시 검사한다(파일이 그대로면 캐시). 검사가 조회를 막으면 모든 원격이 그 사유로 실패한다(fail closed). 원격 수 상한(T15) | 문제 없음. 단 inspector가 모르는 키는 그대로 통과한다(#354, #355, #356) |
| partial clone 게이트 | 설정과 `.promisor` 팩 두 근거로 판단하고, `lazyFetchControlVersion` 미만이면 막는다(#317) | 문제 없음(기존 SEC-T5-18) |
| 인자 | 공통 `-c` → 중화 → fetch 인증 → fetch overrides → subcommand 순서. 뒤의 `-c`가 이긴다. 원격 이름 검증, `--end-of-options`, `--upload-pack=git-upload-pack`, `--no-recurse-submodules`, `--no-tags`, `--refmap=`과 고정 refspec | 문제 없음 |
| 환경 | 변수 allowlist만 전달. `GIT_ALLOW_PROTOCOL`, `GIT_NO_LAZY_FETCH`, `GIT_SSH_COMMAND`(신뢰값 또는 BatchMode), 빈 `GIT_ASKPASS`·`SSH_ASKPASS`·`GIT_PROXY_COMMAND`, 고정 `PATH` | 문제 없음(기존 SEC-T10) |
| 실행 | 저장소별 한 번에 하나, 앱 전체 슬롯 2개. 120초 시간 제한, 취소 시 프로세스 그룹 종료 | 문제 없음(기존 SEC-T15-02) |
| 오류 분류 | 종료 코드로 성공을 판단하고, stderr는 분류에만 쓴 뒤 마스킹한다. 서버가 쓸 수 있는 첫 줄을 요약 문구로 쓰지 않는다 | 문제 없음 |
| 화면 | 문구는 앱이 쓴 것만, 서버 출력은 마스킹한 마지막 5줄만, 줄 단위로 표시용 이스케이프. 진행률은 숫자만 | 터미널 명령 제시 조건에 hook 검사가 없다(관찰 4, #354에서 수정) |

## 4. 저장소가 통제하는 실행·유출 경로와 차단 근거

### 4.1 fetch 중 실행

"대조군"은 평범한 git에서 실행됐는지, "앱"은 앱 인자로 막혔는지다. 세 git은 2.36.6 / Apple 2.54.0 / Homebrew 2.54.0 순서다.

| 경로 | 위협 | 차단 수단 | 대조군 | 앱 | 테스트 ID |
|---|---|---|---|---|---|
| hooks 디렉터리의 `reference-transaction` | T2 | `core.hooksPath=/dev/null` | 실행 ×3 | 차단 ×3 | SEC-T2-01, SEC-T2-02 |
| 설정형 hook `hook.<name>.*` | T2 | 없음 | 2.36 해당 없음, 2.54 실행 | **2.54에서 실행** | #354에서 추가 |
| 로컬 `credential.helper` | T6 | `credential.helper=` 재설정 후 신뢰 helper 재삽입 | 실행 ×3 | 차단 ×3 | SEC-T6-01, SEC-T6-03 |
| 로컬 URL별 `credential.<url>.helper` | T6 | 같음 | 실행 ×3 | 차단 ×3 | SEC-T6-02 |
| 로컬 `core.askPass` | T12 | `-c core.askPass=`, 빈 `GIT_ASKPASS`, `GIT_TERMINAL_PROMPT=0` | 실행 ×3 | 차단 ×3 | SEC-T12-01 |
| 로컬 `core.gitProxy` | T5 | 빈 `GIT_PROXY_COMMAND` | 실행 ×3 | 차단 ×3 | SEC-T5-05 |
| 로컬 `core.sshCommand` | T5 | `GIT_SSH_COMMAND`(신뢰값 또는 기본값)가 설정보다 우선 | 실행 ×3 | 차단 ×3 | SEC-T5-01 |
| `ext::` URL | T5 | `GIT_ALLOW_PROTOCOL`, `protocol.ext.allow=never` | 실행 ×3 | 차단 ×3 | SEC-T5-03 |
| `url.<base>.insteadOf`로 `ext::` 바꿔치기 | T5 | 같음 | 실행 ×3 | 차단 ×3 | SEC-T5-04, SEC-T5-10 |
| `remote.<n>.vcs` | T5 | `GIT_ALLOW_PROTOCOL` | 실행 ×3 | 차단 ×3 | SEC-T5-11 |
| `<helper>::` URL, 저장소의 `protocol.*.allow` | T5 | `GIT_ALLOW_PROTOCOL`이 설정보다 우선 | 실측 안 함 | — | SEC-T5-08, SEC-T5-09, SEC-T5-15, #351 |
| `fd::` URL | T5 | `protocol.fd.allow=never`, `GIT_ALLOW_PROTOCOL` | 실측 안 함 | — | SEC-T5-06 |
| `remote.<n>.uploadpack` | T5 | `--upload-pack=git-upload-pack` | 실행 ×3 | 차단 ×3 | SEC-T5-02 |
| `core.alternateRefsCommand` | T5 | `-c core.alternateRefsCommand=` | 실행 ×3 | 차단 ×3 | SEC-T5-07 |
| partial clone의 lazy fetch | T5 | `GIT_NO_LAZY_FETCH`, 버전 게이트, `.promisor` 팩 | 실측 안 함 | — | SEC-T5-16, SEC-T5-18 |
| 자동 gc·maintenance | T8 | `gc.auto=0`, `maintenance.auto=false`, `fetch.writeCommitGraph=false` | 재현 안 됨 | — | SEC-T8-01, SEC-T8-02 |
| submodule 재귀 fetch | T1·T5 | `--no-recurse-submodules`(인자가 설정보다 우선) | 실측 안 함 | — | 인자 고정만. 실측 테스트 없음 |
| ssh 호스트에 `-o` 옵션 끼워 넣기 | T5 | git 자체가 거부, `--end-of-options` | 실행 안 됨 | 차단 | — (git의 방어) |
| 로컬 경로 원격의 서버 쪽 저장소 설정(hook, fsmonitor) | T5 | upload-pack이 이 설정을 부르지 않음. 앱의 `-c`는 로컬 전송의 upload-pack에 **전달되지 않는다**(git이 다른 저장소용 환경에서 지움, §7) | 실행 안 됨 | 실행 안 됨 | 이 시나리오는 차단 근거가 아님. 다른 서버 쪽 경로는 §7 |

### 4.2 fetch 중 쓰기·유출

| 경로 | 위협 | 차단 수단 | 대조군 | 앱 | 테스트 ID |
|---|---|---|---|---|---|
| 로컬 `http.<url>.proxy`로 자격 증명 받기 | T6·T11 | 신뢰값 또는 빈 값으로 재설정 | 프록시가 Authorization 받음 ×3 | 차단 ×3 | inspector 단위 테스트만. 실제 git 테스트는 #355에서 추가 |
| 그 밖의 로컬 프록시·쿠키 설정 | T6·T11 | 없음 | — | **중화 안 됨 ×3** | #355에서 수정·추가. 상세는 수정 후 이 표에 적는다 |
| 로컬 `http.sslVerify=false` | T11 | `true`로 강제 | 실측 안 함 | — | SEC-T11-03 |
| 로컬 CA·클라이언트 인증서 | T11 | fetch 차단 | 실측 안 함 | — | inspector 단위 테스트 |
| refspec·`tagOpt`·`pruneTags`·`mirror`로 쓰기 범위 넓히기 | T13 | 고정 refspec, `--refmap=`, `--no-tags`, prune 범위 고정 | 실측 안 함 | — | SEC-T13-04 |
| `fetch.bundleURI` | T13 | `-c fetch.bundleURI=` | 실측 안 함 | — | SEC-T13-04 (FetchRefScopeSecurityTests) |
| 부모 환경 변수 | T10 | allowlist | — | — | SEC-T10-01..03 |
| stderr·원격 URL의 자격 증명 | T11 | `CredentialMasker`, 화면은 마스킹 후 마지막 5줄 | — | — | SEC-T11-01, SEC-T11-02, SEC-T11-05 |

### 4.3 대조군에서 재현되지 않은 시나리오

- **자동 gc**: 느슨한 객체를 만들고 `gc.auto=1`로 두었지만, 대조군의 fetch도 gc를 시작하지 않았다. 그래서 앱 쪽 "차단"을 근거로 세지 않았다. 앱의 방어는 인자 우선순위와 기존 SEC-T8 테스트에 기댄다.
- **쿠키 저장 설정**: 시험한 조건에서는 대조군도 파일을 쓰지 않았다. #355에서 함께 다루므로 따로 결론 내지 않았다.

## 5. 조회 경로와 hook

설정형 hook이 조회에도 영향을 주는지 확인했다(#354의 범위를 정하려고).

- 저장소: 로컬 설정에 git의 hook 이벤트 26개 전부를 건 설정형 hook. stat만 바뀐 파일, untracked 파일, stash, 연결 워크트리 포함.
- 실행: `ReadOnlyGitCommand`의 조회 전부를 앱 인자·환경(전송 없음)으로 실행.
- 결과(Apple 2.54.0, Homebrew 2.54.0): **hook 실행 0회.** 대조군으로 같은 저장소에서 평범한 `git commit`을 하면 hook이 실행됐다.
- 결론: #354의 영향은 fetch(`reference-transaction`)와, 사용자가 터미널에서 직접 실행하는 git이다.

## 6. git 2.40–2.54 릴리스 노트 점검

설정으로 실행·저장소 밖 파일 접근·네트워크가 생기는 기능을 찾았다. 아래 "후보"는 **문서 근거만 있고, 실측과 조치는 #356에서 한다.**

| 도입 | 설정 | 성격 | 앱 명령에서 | 처리 |
|---|---|---|---|---|
| 2.40–2.54 | 저장소 밖 경로 지정, 자격 증명 보호 스위치, promisor 수락, mailmap 관련 설정 4건 | 파일 접근·네트워크 | 조회 또는 fetch | 후보. 문서 근거, #356에서 실측·조치. 키와 실측 결과는 #356 수정 후 이 표에 적는다 |
| 2.44 | `fetch.all` | 모든 원격 fetch | 해당 없음(앱은 원격 이름을 항상 넘김) | 조치 불필요 |
| 2.48 | `remote.<n>.serverOption` | 저장소가 정한 문자열을 그 원격 서버로 보냄 | fetch | 같은 서버로만 감. 조치 불필요 |
| 2.46 | `http.proactiveAuth` | 401 없이 자격 증명 전송 | fetch | 같은 호스트로만 감. 프록시와 겹치는 부분은 #355 |
| 2.54 | 설정형 hook, `reference-transaction`의 preparing 단계 | 실행 | fetch | #354 |
| 2.49 | `help.autoCorrect` | 실행 | fetch 경로와 터미널 | fetch 경로는 #350(#351)에서 `-c help.autocorrect=0`으로 무력화. 그 밖은 Terminal 가드(T14) 범위 |
| 2.42·2.41 등 | `gc.recentObjectsHook`, `sendemail.headerCmd`, `mergetool/difftool.guiDefault` | 실행 | 터미널에서만 | Terminal 가드(T14) 범위. `gc.recentObjectsHook`은 #356에서 검사 목록에 추가 |

## 7. 독립 점검 (security-reviewer)

`main`(#351 머지 후)을 기준으로 security-reviewer 에이전트에게 같은 범위를 점검시켰다. 이 보고서의 결론은 알려 주지 않았고, 에이전트도 이 보고서를 읽지 않았다. 코드와 문서만 읽는 점검이었고 실측은 하지 않았다.

- **이 보고서와 겹친 것**: 프록시·쿠키 설정(#355), 터미널 안내의 hook 검사(#354), 최신 git의 자격 증명 보호 스위치(#356).
- **새로 나온 것** (비공개로 먼저 보고. 상세는 수정 후 이 표에 적는다):

  | 항목 | 심각도 | 처리 |
  |---|---|---|
  | 오래된 git에서 로컬 경로 원격의 fetch | 높음 | #361 (실측부터) |
  | 원격 URL에 든 자격 증명 | 중간 | #356에 범위 추가 |
  | fetch 실패 상세 줄의 길이 | 낮음 | #362 |
  | 저장소 프록시를 빈 값으로 덮으면 회사 프록시 환경에서 fetch가 실패함(기능 문제, 보안 중립) | — | #355에서 사용자의 실효 프록시 값으로 덮도록 수정 |

- **이 보고서의 정정**: §4.1의 "로컬 경로 원격의 서버 쪽 저장소 설정" 행에 처음에는 "앱의 `-c`가 하위 프로세스에도 전달된다"고 적었다. 로컬 전송에서는 git이 다른 저장소용 환경을 만들 때 이 값을 지운다. 그 시나리오에서 아무것도 실행되지 않은 것은 upload-pack이 그 설정을 부르지 않기 때문이었다. 행을 고쳤고, 그 경로의 다른 시나리오는 #361에서 본다.
- 프로세스 그룹 종료, stdin, CLOEXEC, 출력 상한, 시간 제한, 인자 순서, `=`가 든 키 차단, 화면 이스케이프는 문제없다고 보았다.

## 8. 남은 위험과 하지 않은 것

- 실측은 하네스로 했다. 하네스는 이 보고 시점의 `GitEnvironment`·`FetchCommand`·inspector 인자를 옮겨 적은 것이라, 앱 코드가 바뀌면 하네스와 어긋날 수 있다. 앱 코드 자체의 회귀 방지는 SEC 테스트가 맡는다.
- §4에서 "실측 안 함"인 행은 기존 SEC 테스트를 근거로 삼았다.
- 릴리스 노트 점검은 정식 릴리스의 주요 절을 읽고 포인트 릴리스와 Fixes 절은 키워드로 훑었다. 키워드에 걸리지 않은 항목은 빠졌을 수 있다.
- 독립 점검이 낮음으로 본 잔여 위험(조치 없음):
  - 사용자 global 설정의 `includeIf "hasconfig:remote.*.url:…"`은 저장소가 원격 URL을 추가하는 것만으로 켜진다. 그 파일의 설정(예: 헤더, helper)은 신뢰 scope로 보여 그 원격으로 가는 fetch에도 적용된다. 사용자가 그런 설정을 둔 경우에만 성립한다.
  - ssh 호스트 이름의 글자는 git이 `-`로 시작하는 것만 거부한다. 사용자의 ssh 설정에 `%h`를 쓰는 `ProxyCommand`가 있고 OpenSSH가 오래된 경우 문제가 될 수 있다. BatchMode라 처음 보는 호스트는 인증 전에 실패한다.
  - 그 밖의 http 설정(이름 해석 고정, 추가 헤더 등)은 실행 경로가 없고 영향이 낮다.
- Apple Git과 Homebrew git이 둘 다 2.54.0이라, 2.37–2.53 사이의 동작은 직접 보지 않았다. 설정형 hook이 처음 들어온 버전도 확인하지 않았다(#354가 버전과 관계없이 막는 쪽으로 고친다).

## 9. 제안: git이 바뀔 때마다 하는 점검

이번 결함 두 종류(설정형 hook, 원격별 프록시)는 모두 "앱이 막는 키 목록에 없는, git이 새로 읽거나 원래 읽던 설정"이었다. 공통 인자와 inspector는 아는 키만 막는다. 그래서 git이 바뀔 때 새 키를 찾는 절차를 둔다.

1. **언제**: 최소 지원 버전을 올릴 때, 그리고 git-compat 워크플로(#292, #345)가 시험하는 git 버전을 바꿀 때. Xcode나 Homebrew의 git이 새 minor 버전으로 올라갔을 때도 한다.
2. **릴리스 노트 확인 항목**: 새 minor 버전의 릴리스 노트와 그 사이 보안 릴리스에서 다음을 찾는다.
   - 프로그램이나 셸 명령을 실행하는 설정(hook, `*.command`, `*.program`, `*Cmd`, helper)
   - 경로를 받는 설정(`*.file`, `*Path`, 저장 위치 URI)
   - 접속 대상이나 보낼 내용을 바꾸는 설정(proxy, cookie, auth, server option, promisor, bundle)
   - 보안 완화를 끄는 스위치(`protect*`, `sanitize*`)
   - fetch나 조회가 새로 일으키는 hook 이벤트
3. **분류**: 찾은 키마다 앱 명령(조회, fetch)에서 발동하는지 판단한다. 발동하면 security-review.md §3.3 표에 위협과 처리(중화, 경고, 차단, fail closed)를 적고, inspector 분류와 SEC 테스트를 추가한다. 터미널에서만 발동하면 Terminal 가드(T14) 보고 대상인지 판단한다.
4. **실측**: 무해한 canary로 대조군(평범한 git에서 실행됨)과 앱 인자(막힘)를 짝으로 확인한다. 대조군이 실행되지 않는 시나리오는 근거로 세지 않는다.
5. **자동화와 연결**: git-compat 워크플로가 새 git을 받을 때 SEC 테스트 전체가 그 git으로 돌므로, 3에서 추가한 테스트가 다음 버전의 회귀를 잡는다. 워크플로가 시험 대상 git 버전을 바꾸는 PR에는 이 점검을 체크리스트 항목으로 둔다(`docs/qa/release-checklist.md` 또는 PR 템플릿).
6. **기록**: 점검 결과는 `docs/qa/reports/`에 git 버전별로 짧게 남긴다(이 보고 §6 형식).
