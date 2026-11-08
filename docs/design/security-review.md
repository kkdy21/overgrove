# 보안 검토 (위협 모델)

> 상태: Accepted (Phase 2 게이트, 2026-11-05) · 관련: ADR-0004, ADR-0006, ADR-0008, ADR-0009, ADR-0018, [../architecture/git-command-catalog.md](../architecture/git-command-catalog.md), [../architecture/overview.md](../architecture/overview.md)

Overgrove는 **사용자가 고른 로컬 저장소에 대해 시스템 `git`을 실행하는 앱**이다. 저장소는 신뢰할 수 없다고 가정한다. 예를 들어 처음 클론한 오픈소스, 받은 압축 파일, AI 에이전트가 만든 워크트리일 수 있다. 이 문서는 위협 T1–T19 각각에 대해 시나리오, 대응, 잔여 위험, 검증 테스트를 정의한다.

---

## 1. 범위와 가정

### 1.1 보호 대상

1. 사용자 계정에서 임의 코드가 실행되지 않을 것
2. 자격 증명(토큰, 비밀번호, SSH 키)이 노출되지 않을 것
3. 저장소와 작업 트리가 의도치 않게 바뀌지 않을 것
4. 앱이 멈추거나 시스템 자원을 고갈시키지 않을 것
5. 공개 저장소(이 프로젝트 자체)에 비밀 정보가 섞이지 않을 것

### 1.2 신뢰 경계

| 신뢰함 | 신뢰하지 않음 |
|---|---|
| macOS, `/usr/bin/git`(Apple 서명), 사용자가 설치한 `gh`, `glab`, `gt`(v0.2.0, ADR-0026. 실행 전에 버전 출력 형식을 확인한다) | 저장소 안의 모든 것: 작업 트리 파일, `.gitattributes`, `.gitmodules` |
| git의 `system`, `global`, `unknown`(Apple 내장), `command` scope 설정 | `.git/config`(`local`), `config.worktree`(`worktree`), 그 설정이 include한 파일 |
| 사용자가 `NSOpenPanel`로 고른 경로 | `.git/info/attributes`, `.git/hooks/*`, 서브모듈의 `.git/modules/*/config` |
| 설정에서 사용자가 고른 git 실행 파일 중 [ADR-0019](../adr/0019-user-chosen-git-executable.md)의 경로·소유자·권한·버전 규칙을 통과한 것 (v0.2.0, #106) | 등록된 저장소 안에 있거나, root·현재 사용자가 아닌 소유자, other 쓰기, `admin`·`wheel`이 아닌 group 쓰기 권한이 있는 경로의 실행 파일 |
| | 원격 서버 응답, 원격 저장소 내용 |

global 설정이나 사용자 홈 디렉터리를 악성 코드가 바꾸는 경우는 이 앱의 위협 모델 밖이다. 그 상태라면 이미 계정이 장악된 것이다.

### 1.3 공격자 모델

- 저장소 파일과 `.git` 디렉터리 내용을 마음대로 만들 수 있다 (악성 저장소를 배포하는 공격자).
- 원격 서버를 운영할 수 있다 (악성 원격).
- 사용자를 속여 앱에 저장소를 등록하게 할 수 있다.
- 공개 저장소에 fork PR을 열 수 있다. head 브랜치 이름은 마음대로 정한다(PR 상태 표시의 사칭, T9 대응 8, ADR-0023).
- 사용자 계정의 global 설정과 앱 바이너리는 바꿀 수 없다.

---

## 2. 위협별 분석

상태 표기: **설계 완료**는 대응이 정의되어 있고 구현 전이라는 뜻이다. **적용됨**은 저장소 셋업에서 이미 적용했다는 뜻이다. **확인**은 Apple Git 2.50.1 실험(§4)으로 검증한 사실이다.

위협마다 파일 하나를 둔다(#457). 각 파일에 설명, 시나리오, 대응, 잔여 위험, 검증 테스트, 상태가 있다. 검증 테스트는 한 줄에 하나씩 쓰고, 새 SEC ID는 [§2.1](#21-sec-id-규칙)을 따른다.

| 위협 | 내용 |
|---|---|
| [T1](threats/T1.md) | `core.fsmonitor` 실행 |
| [T2](threats/T2.md) | hooks 실행 |
| [T3](threats/T3.md) | 외부 diff, textconv 실행 |
| [T4](threats/T4.md) | clean/smudge/process 필터 실행 |
| [T5](threats/T5.md) | 전송 계층 명령 실행 |
| [T6](threats/T6.md) | 저장소 로컬 `credential.helper` 실행 |
| [T7](threats/T7.md) | 서명 검증 프로그램 실행 |
| [T8](threats/T8.md) | fetch 중 자동 gc·maintenance |
| [T9](threats/T9.md) | 인자 인젝션 |
| [T10](threats/T10.md) | 부모 환경 변수 상속 |
| [T11](threats/T11.md) | 자격 증명 노출 |
| [T12](threats/T12.md) | 자격 증명 프롬프트 대기 |
| [T13](threats/T13.md) | 의도치 않은 쓰기 명령 실행 |
| [T14](threats/T14.md) | 파일 시스템 범위 이탈, 심볼릭 링크 탈출 |
| [T15](threats/T15.md) | 자원 고갈 |
| [T16](threats/T16.md) | 로그를 통한 정보 유출 |
| [T17](threats/T17.md) | 공급망 |
| [T18](threats/T18.md) | 공개 저장소에 비밀 정보·개인 경로 커밋 |
| [T19](threats/T19.md) | 디스크에 남는 저장소 데이터 |

### 2.1 SEC ID 규칙

- 형식은 `SEC-T<위협 번호>-<이슈 번호>-<순번>`이다. 예: 이슈 #500에서 T9 테스트를 둘 더하면 `SEC-T9-<500>-1`과 `SEC-T9-<500>-2`처럼 꺾쇠 없이 쓰고, 테스트 이름은 `testSECT9_<500>_1_…`처럼 꺾쇠 없이 쓴다. 이슈 번호가 겹치지 않으므로 동시에 열린 PR이 같은 번호를 고를 일이 없다.
- 그 전의 두 자리 ID(`SEC-T9-05` 등)는 그대로 쓴다. 목록은 `scripts/lint/sec-ids-legacy.txt`에 고정되어 있고, 새 두 자리 ID는 `scripts/lint/check-sec-ids.sh`가 거부한다.
- ID는 그 위협 파일의 **검증** 목록에서 `  - SEC-T…-… (설명)` 형태로 한 번만 정의한다. 다른 곳의 언급은 참조다.

---

## 3. 최종 규칙 목록

이 절의 목록은 [git-command-catalog.md §2](../architecture/git-command-catalog.md)와 같아야 한다. 바꿀 때는 두 문서를 함께 고친다.

### 3.1 공통 보안 인자 (모든 git 호출, 서브커맨드 앞)

```
--no-pager
--no-optional-locks
--literal-pathspecs
-c core.fsmonitor=false
-c core.hooksPath=/dev/null
-c core.askPass=
-c protocol.ext.allow=never
-c protocol.fd.allow=never
-c alias.remote-https=
-c alias.remote-ssh=
-c alias.remote-git=
-c alias.remote-file=
-c alias.remote-http=
-c help.autocorrect=0
-c core.alternateRefsCommand=
-c log.showSignature=false
-c gc.auto=0
-c maintenance.auto=false
-c diff.autoRefreshIndex=false
-c color.ui=never
-c diff.suppressBlankEmpty=false
-c i18n.logOutputEncoding=UTF-8
-c log.follow=false
-c log.mailmap=false
-c mailmap.file=
-c mailmap.blob=
```

diff 계열 서브커맨드에는 `--no-ext-diff --no-textconv`를 붙인다.
porcelain diff(`worktreeDiff`, `worktreeNumstat`, `untrackedPreview`, `comparePatch`, `compareFiles`)에는 `--no-color --src-prefix=a/ --dst-prefix=b/ --submodule=short`를 붙인다(#239).
status와 작업 트리를 보는 diff(`worktreeDiff`, `worktreeNumstat`, `compareFiles`, `comparePatch`)에는 `--ignore-submodules=dirty`를 붙인다.
fetch에는 `--no-recurse-submodules --upload-pack=git-upload-pack`을 붙인다.

### 3.2 환경 변수 allowlist

| 변수 | 값 |
|---|---|
| `LC_ALL`, `LANG` | `C` |
| `GIT_TERMINAL_PROMPT` | `0` |
| `GIT_OPTIONAL_LOCKS` | `0` |
| `GIT_PAGER`, `PAGER` | `cat` |
| `GIT_ASKPASS`, `SSH_ASKPASS` | 빈 문자열 |
| `GIT_PROXY_COMMAND` | 빈 문자열 |
| `GIT_ALLOW_PROTOCOL` | 기본·조회: 빈 값(전송 없음, lazy fetch 차단, #212). fetch만 명시적으로 `https:ssh:git:file:http`(내장 전송만). 기본값이 "전송 없음"이라 고르지 않은 호출부는 네트워크를 쓰지 못한다(#215). 부모 값은 무시. 신뢰하지 않음 저장소(#107)와 `lazyFetchControlVersion` 미만 git(#361)의 fetch는 `file`을 뺀 `https:ssh:git:http`. |
| `GIT_NO_LAZY_FETCH` | `1` (모든 명령, promisor lazy fetch 금지. 모든 경로를 막는 것은 2024년 5월 보안 릴리스(2.45.1, 2.44.1, 2.39.4·2.40.2·2.41.1·2.42.2·2.43.4)부터, #212·#317) |
| `GIT_SSH_COMMAND` | 신뢰 scope `core.sshCommand` 또는 `ssh -o BatchMode=yes` |
| `PATH` | `/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin` |
| `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SSH_AUTH_SOCK` | 부모 값 |

gh 전용 추가 변수는 [카탈로그 §5](../architecture/git-command-catalog.md)에, glab·gt 전용은 §5.1에 있다.

셸 프록시 변수(`HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`, `NO_PROXY`와 소문자 변형)는 넘기지 않는다([ADR-0022](../adr/0022-no-shell-proxy-env-vars.md)). Finder에서 실행한 앱에는 어차피 닿지 않아 실행 방식마다 동작이 달라지고, 부모 환경을 신뢰하게 되기 때문이다. 프록시는 전역 `http.proxy`로 둔다([가이드](../guides/self-hosted-git.ko.md#프록시)).

### 3.3 RepoConfigInspector 탐지 키

키는 `section.subsection.variable` 형식이다. section과 variable은 소문자로 정규화된 상태에서 비교하고, subsection은 `.`이 들어갈 수 있다. 대상 scope는 `local`과 `worktree`다.

| 정규식 | 범주 | 처리 | 위협 |
|---|---|---|---|
| `^filter\.(.+)\.(clean\|smudge\|process\|required)$` | 실행 | **무력화**: 드라이버별 `-c` 4종 (모든 명령) | T4 |
| `^hook\.(.+)\..+$` (설정형 hook, git 2.54+) | 실행 | **무력화**: 이름별 `-c hook.<이름>.enabled=false` (모든 명령). 이름을 쓸 수 없거나 256개를 넘으면 **조회 차단**. 이름 없는 `hook.<키>`는 보고만 (#354) | T2 |
| `^credential\.helper$`, `^credential\..+\.helper$` | 실행 | **무력화**: 초기화 + 신뢰 항목 재삽입 (fetch) | T6 |
| `^core\.sshcommand$` | 실행 | **무력화**: `GIT_SSH_COMMAND` (항상) | T5 |
| `^core\.gitproxy$` | 실행 | **무력화**: 빈 `GIT_PROXY_COMMAND` (항상) | T5 |
| `^remote\..+\.uploadpack$` | 실행 | **무력화**: `--upload-pack` (fetch, 항상) | T5 |
| `^http\.(.+\.)?sslverify$` | 전송 보안 | **무력화**: 값과 관계없이 같은 키 `=true` (fetch). git은 `0k`, `0x0`, `-0` 등도 false로 읽으므로 추측하지 않는다 (#150 리뷰) | T11 |
| `^http\.(.+\.)?proxy$` | 전송 보안 | **무력화**: 같은 키에 그 URL에 대한 신뢰 실효 프록시(가장 구체적인 신뢰 `http.<url>.proxy` → 신뢰 `http.proxy`), 없으면 빈 값 (fetch). 로컬 프록시가 신뢰 helper가 내준 자격 증명을 받을 수 있다 (#150 리뷰 실측, #355) | T11 |
| `^remote\..+\.proxy$` | 전송 보안 | **무력화**: 같은 키에 신뢰 값, 없으면 원격 URL에 대한 신뢰 실효 프록시, 없으면 빈 값 (fetch, 그 원격에서 `http.proxy`보다 우선). subsection에 `=`가 있거나 UTF-8이 아니면 덮어쓸 수 없어 조회를 막는다 (#355) | T11 |
| `^http\.(.+\.)?proxyauthmethod$`, `^remote\..+\.proxyauthmethod$` | 전송 보안 | **무력화**: 같은 키에 신뢰 값(`proxy`와 같은 찾기: 같은 키 → 가장 구체적인 신뢰 `http.<url>.proxyAuthMethod` → 신뢰 `http.proxyAuthMethod`), 없으면 `anyauth` (fetch). `basic`이면 프록시 비밀번호가 평문으로 간다. 원격 키의 subsection에 `=`가 있거나 UTF-8이 아니면 조회를 막는다 (#367 실측) | T11 |
| `^http\.(.+\.)?(proxysslcertpasswordprotected\|sslcertpasswordprotected)$` | 전송 보안 | **무력화**: 같은 키에 신뢰 값(값 없이 쓴 신뢰 키는 `true`), 없으면 `false` (fetch). 켜면 git이 신뢰 helper에 인증서 비밀번호를 묻는다 (프록시 키는 #367 실측, 원격 키는 소스 기준·미측정) | T11 |
| `^http\.(.+\.)?delegation$` | 전송 보안 | **무력화**: fetch overrides가 `http.delegation=none`, 저장소의 URL별 키는 같은 키에 `none` (fetch). 고정값은 사용자의 generic 값도 끈다. 저장소가 사용자 키보다 구체적인 URL 키를 두면 그 원격에서는 사용자의 URL별 위임도 꺼진다(쿠키와 같은 구조, 안전한 쪽). `always`면 Kerberos 티켓을 저장소가 고른 원격 호스트에 위임할 수 있다. 측정 안 함(Kerberos 환경 없음), 인자 수준 확인 (#367) | T11 |
| `^http\.(.+\.)?cookiefile$`, `^http\.(.+\.)?savecookies$` | 전송 보안 | **무력화**: 같은 키에 빈 값·`false` (fetch). generic 키는 fetch overrides도 끈다. 저장소가 고른 파일을 쿠키 저장소로 읽고 쓰지 않게 한다 (#355) | T11 |
| `^core\.fsmonitor$` | 실행 | 보고 (공통 인자로 차단) | T1 |
| `^core\.hookspath$` | 실행 | 보고 (공통 인자로 차단) | T2 |
| `^core\.askpass$` | 실행 | 보고 (공통 인자와 환경으로 차단) | T12 |
| `^diff\.external$`, `^diff\..+\.(textconv\|command)$` | 실행 | 보고 (`--no-ext-diff --no-textconv`) | T3 |
| `^gpg\.(.+\.)?program$`, `^log\.showsignature$` | 실행 | 보고 (공통 인자, 서명 포맷 금지) | T7 |
| `^protocol\.(.+\.)?allow$` | 전송 | 보고 (`GIT_ALLOW_PROTOCOL`이 모든 값보다 우선, `ext`·`fd`는 공통 인자로도 never) | T5 |
| `^remote\..+\.url$` (값이 `<helper>::`로 시작: `^([A-Za-z0-9][A-Za-z0-9+.-]*)?::`, `ext::`·`fd::` 포함. 또는 `<scheme>://`인데 scheme이 `http`·`https`·`ftp`·`ftps`·`git`·`ssh`·`git+ssh`·`ssh+git`·`file`이 아님, 대소문자 무시) | 전송 | 보고 (`GIT_ALLOW_PROTOCOL`로 차단됨, #161, `TransportName`) | T5 |
| `^remote\..+\.vcs$` | 전송 | 보고 (원격 helper 지정, `GIT_ALLOW_PROTOCOL`로 차단됨, #161) | T5 |
| `^remote\..+\.(promisor\|partialclonefilter)$`, `^extensions\.partialclone$` | 전송 | **무력화**: 조회는 전송을 쓰지 않음(빈 `GIT_ALLOW_PROTOCOL`, `GIT_NO_LAZY_FETCH=1`). 누락 객체가 필요한 조회는 실패한다. fetch는 `lazyFetchControlVersion`(git 2.45.1) 이상에서만 허용(그 전에는 partial clone fetch 거부) (#212, #317) | T5 |
| `^remote\.<n>\.fetch$` (대상이 `refs/remotes/<n>/` 밖. 대상 없는 refspec과 `^` negative refspec 제외) | 쓰기 | **무력화**: fetch는 명령줄 refspec + `--refmap=`만 쓴다 (#209) | T13 |
| `^fetch\.prunetags$`, `^remote\..+\.prunetags$`, `^remote\..+\.tagopt$` | 쓰기 | **무력화**: `-c …pruneTags=false`, `--no-tags` (#209) | T13 |
| `^fetch\.bundleuri$` | 쓰기·전송 | **무력화**: `-c fetch.bundleURI=` (임의 URI에서 bundle을 받아 `refs/bundles/*`를 쓰는 것을 막음, #210 보안 검토) | T13 |
| `^transfer\.bundleuri$` | 전송 | **무력화**: `-c transfer.bundleURI=false` (fetch). git은 이 키를 clone에만 쓴다(E47, #195). 나중 git이 fetch에서도 읽을 때를 대비한 심층 방어 | T13 |
| `^remote\..+\.mirror$` | 쓰기 | 보고 (fetch는 명령줄 refspec만 쓰므로 영향 없음, #209) | T13 |
| `^url\..+\.(insteadof\|pushinsteadof)$` | 전송 | 보고 | T5 |
| `^http\.(.+\.)?(sslcainfo\|sslcapath\|sslcert\|sslkey)$` | 전송 보안 | 경고 + **fetch 차단** (조회는 허용). 프록시 TLS 인증서 파일·`curloptResolve`는 아래 #356 행 | T11 |
| `http`·`credential`·`filter` 키와 `remote.<n>.proxy`·`proxyAuthMethod`의 subsection에 `=` | 구성 | **조회 차단**: git이 `-c`를 첫 `=`에서 잘라 다른 키를 주입할 수 있다 (#150 리뷰) | T9 |
| `^includeif\.onbranch:` | 구성 | 캐시하지 않음 (HEAD에 따라 설정이 바뀜) | — |
| `^core\.worktree$` | 범위 | 경고 | T14 |
| `^core\.(attributesfile\|excludesfile)$`, `^diff\.orderfile$` | 자원 | 경고 (FIFO·장치를 가리키면 타임아웃까지 git이 멈출 수 있음, #148 리뷰) | T15 |
| `^include\.path$`, `^includeif\..+\.path$` | 구성 | 보고 (`--includes`로 함께 검사함) | — |
| `^fetch\.recursesubmodules$`, `^submodule\.recurse$` | 전송 | 보고 (`--no-recurse-submodules`) | T5 |
| `^submodule\..+\.update$` (값이 `!`로 시작) | 실행 | 보고 (앱이 쓰지 않는 명령) | — |
| `^gc\.auto$`, `^maintenance\.auto$`, `^maintenance\..+` | 쓰기 | 보고 (공통 인자로 끔) | T8 |
| `^core\.alternaterefscommand$` | 실행 | 보고 (alternates가 있으면 fetch에서 실행됨, 공통 인자 `-c core.alternateRefsCommand=`로 차단) | T5 |
| `^uploadpack\.packobjectshook$` | 실행 | 보고 (조회·fetch에서는 실행되지 않음, 의심 신호) | — |
| `^safe\.directory$` | 구성 | 보고 (local scope에서는 git이 무시함, 의심 신호) | — |
| `^i18n\.(logoutputencoding\|commitencoding)$` | 출력 | 보고 (공통 인자 `-c i18n.logOutputEncoding=UTF-8`로 고정, #205) | T15 |
| `^core\.pager$`, `^pager\..+` (값이 git 불리언이 아님) | 실행 | 보고. 앱은 `--no-pager`·`GIT_PAGER=cat`으로 쓰지 않는다. Open in Terminal 확인 사유다(#278). `pager.<cmd>=false`/`true`는 명령이 아니라 보고하지 않는다 | T14 |
| `^core\.editor$`, `^sequence\.editor$` | 실행 | 보고. 앱은 편집기를 띄우는 명령이 없다. Open in Terminal 확인 사유다(#278) | T14 |
| `^alias\..+` (값이 `!`로 시작) | 실행 | 보고. 앱은 alias를 쓰지 않는다. Open in Terminal 확인 사유다(#278) | T14 |
| `^credential\.(.+\.)?(protectprotocol\|sanitizeprompt)$` | 자격 증명 | **무력화**: fetch overrides가 generic 키를 `true`로 고정하고, URL별 키는 같은 키로 `true` (fetch, #356) | T6 |
| `^promisor\..+` | 전송 | **무력화**: `-c promisor.acceptFromServer=none` (fetch). 보고 (#356) | T5 |
| `^mailmap\.(file\|blob)$`, `^log\.mailmap$` | 파일 | **무력화**: 공통 인자 `-c log.mailmap=false -c mailmap.file= -c mailmap.blob=` (모든 명령). 보고 (#356) | T15 |
| `^extensions\.refstorage$` (값이 `files`·`reftable`이 아님) | 쓰기 | 경고 + **fetch 차단**. 조회는 계속한다 (#356) | T13 |
| `^http\.(.+\.)?(proxysslcainfo\|proxysslcert\|proxysslkey)$` | 전송 보안 | 경고 + **fetch 차단** (`sslCAInfo` 계열과 같다, #356) | T11 |
| `^http\.(.+\.)?curloptresolve$` | 전송 보안 | 경고 + **fetch 차단** (호스트 이름을 저장소가 고른 주소로 고정, git 2.37+, #356) | T11 |
| `^gc\.recentobjectshook$` | 실행 | 보고. 앱은 gc를 실행하지 않는다. Open in Terminal 확인 사유다 (git 2.42+, #356) | T14 |

필터 드라이버 이름이 `^[A-Za-z0-9._-]{1,64}$`를 벗어나면 무력화 인자를 안전하게 만들 수 없다. 이때는 조회를 막는다 (fail closed).

#### 최신 git이 읽는 설정 (#356)

#353의 git 2.40–2.54 릴리스 노트 점검에서 나온 후보와 그 뒤 리뷰에서 더한 항목이다. 비용이 작은 방어는 실측 결과와 관계없이 적용했다. 고정 인자는 그 키를 모르는 git에서 무시된다(git 2.36.6에서 log·fetch 결과가 같음을 확인). 실측은 git 2.36.6과 Apple Git 2.54.0으로 했다.

| 설정 | 도입 | 실측 | 조치 |
|---|---|---|---|
| `extensions.refStorage`의 위치 지정(`files://<경로>` 등) | 2.54 (`refStorage` 자체는 2.45) | 2.54: 조회가 그 위치의 ref를 읽고, fetch가 그 위치에 ref와 reflog를 씀(저장소 밖 쓰기). 2.36: 확장을 몰라 git 디렉터리를 무시하므로 저장소 명령이 스스로 실패함 | 값이 `files`·`reftable`이 아니면 경고 + fetch 차단. 조회는 계속한다(밖의 ref를 읽어 표시가 틀릴 수 있을 뿐 쓰지 않음). 값 없는 `reftable`은 정상 저장소 형식이라 보고하지 않는다 |
| `credential.protectProtocol`, `credential.sanitizePrompt` | 2.48.1, 2.40.4 등 보안 릴리스(CVE-2024-52006, CVE-2024-50349) | 2.36에서 키 무시 확인. 끈 상태의 동작은 실측 안 함 | fetch overrides에 `true` 고정. URL별 키는 같은 키로 `true` |
| `transfer.credentialsInUrl` (URL의 비밀번호) | 2.37 | 2.54: `die`면 접속 전에 실패. 2.36: 키를 무시하고 URL의 비밀번호로 접속 | fetch overrides에 `die` 고정. 원격 URL(바꿔치기 포함)에 비밀번호가 있으면 검사가 그 원격의 fetch를 git 실행 전에 거부(모든 버전) |
| `promisor.acceptFromServer`, `promisor.storeFields` | 2.49, 2.52 | 실측 안 함(서버가 promisor를 광고해야 함). 2.36에서 키 무시 확인 | fetch overrides에 `none` 고정. 보고 |
| `mailmap.file`, `mailmap.blob`, `log.mailmap` | 오래된 키 | 두 버전 모두 `mailmap.file`이 FIFO면 앱의 기존 인자로도 `git log`가 시간 제한까지 멈춤. 고정 인자로 바로 끝남. 앱 표시(`%an`)는 그대로 | 공통 인자로 끔. 보고 |
| `http.curloptResolve` | 2.37 | 실측 안 함 | 경고 + fetch 차단 |
| `http.proxySSLCAInfo`·`proxySSLCert`·`proxySSLKey` | 2.29 무렵 (문서 근거) | 실측 안 함 | 경고 + fetch 차단(`sslCAInfo` 계열과 같다) |
| `gc.recentObjectsHook` | 2.42 | 앱은 gc를 실행하지 않음 | 보고(Open in Terminal 확인 사유) |

---

## 4. 실험 기록

Phase 2에서 Apple Git 2.50.1 (Apple Git-155), gh 2.95.0으로 격리된 임시 HOME과 임시 저장소를 만들어 확인했다. 실행 경로는 canary 파일 생성 여부로 판정했다. 이 실험은 Phase 3에서 악성 픽스처 기반 SEC 테스트로 옮긴다.

### 4.1 확인한 사실

| # | 실험 | 결과 |
|---|---|---|
| E1 | 로컬 `core.fsmonitor` + `status` | 실행됨. `-c core.fsmonitor=false`면 실행 안 됨 |
| E2 | `worktree list`, `log`, `for-each-ref`, `stash list` + 로컬 fsmonitor | 실행 안 됨 |
| E3 | `reference-transaction` 훅 + `fetch` | 실행됨. `-c core.hooksPath=/dev/null`이면 실행 안 됨 |
| E4 | `filter=evil` 속성 + 로컬 clean + stat 변경 + `status` (`GIT_OPTIONAL_LOCKS=0`) | 실행됨, 다음 status에서도 다시 실행됨 |
| E5 | E4 + `-c filter.evil.{clean,smudge,process}=` | 실행 안 됨 |
| E6 | E5 + 로컬 `required=true` | `fatal: clean filter 'evil' failed`. `-c filter.evil.required=false`를 더하면 성공 |
| E7 | `--attr-source=<empty tree>` | 트리 `.gitattributes`는 막음, `.git/info/attributes`는 못 막음 |
| E8 | 로컬 `remote.origin.uploadpack` + 로컬 경로 원격 fetch | 실행됨. `-c remote.origin.uploadpack=git-upload-pack`은 "more than one uploadpack given, using the first"로 무시됨. `--upload-pack=git-upload-pack`이면 실행 안 됨. `fetch --all`도 이 옵션을 전달함 |
| E9 | 로컬 `core.sshCommand` + ssh 원격 fetch | 실행됨. 환경 변수 `GIT_SSH_COMMAND`가 우선함. `-c core.sshCommand=`(빈 값)은 `cannot run :` 오류 |
| E10 | `ext::` 원격 + 로컬 `protocol.ext.allow=always` | 실행됨. `-c protocol.ext.allow=never`면 `transport 'ext' not allowed` |
| E11 | `url.<ext::...>.insteadOf` 바꿔치기 | `allow=never`가 없으면 실행됨, 있으면 차단 |
| E12 | 로컬 `core.gitProxy` + `git://` 원격 | 실행됨. `-c core.gitProxy=`로는 여전히 실행됨. 빈 `GIT_PROXY_COMMAND` 환경 변수면 실행 안 됨. `-c protocol.git.allow=never`도 차단 |
| E13 | `fd::` 원격 | 기본 허용. 오류 뒤 정지. `-c protocol.fd.allow=never`면 즉시 차단 |
| E14 | fetch 후 auto maintenance | `git maintenance run --auto` 실행됨 (`GIT_TRACE`). `-c gc.auto=0 -c maintenance.auto=false`면 실행 안 됨 |
| E15 | 로컬 generic credential helper (global helper가 자격 증명을 주지 않는 경우) | 실행됨. `-c credential.helper= -c credential.helper=<global>`이면 global만 실행 |
| E16 | 로컬 URL별·와일드카드 credential helper + generic 초기화 | 실행 안 됨 (generic 초기화가 URL별 항목도 비움) |
| E17 | 초기화 후 URL별 빈 값을 신뢰 helper보다 뒤에 넣음 | 신뢰 helper도 실행 안 됨 → 순서가 중요 |
| E18 | 초기화 + 신뢰 URL별 helper 재삽입 | 신뢰 helper만 실행 |
| E19 | 로컬 `core.askPass` + `GIT_TERMINAL_PROMPT=0` | 실행됨. `-c core.askPass=` 또는 빈 `GIT_ASKPASS`면 실행 안 됨 |
| E20 | 서명 커밋 + 로컬 `gpg.program` | `%G?` 포맷이면 실행됨, 일반 포맷이면 실행 안 됨 |
| E21 | E20 + 로컬 `log.showSignature=true` | 일반 `log`/`show`도 실행됨. `-c log.showSignature=false` 또는 `--no-show-signature`면 실행 안 됨 |
| E22 | textconv + `show -p` | 실행됨. `--no-ext-diff`만으로는 실행됨, `--no-textconv`까지 있어야 막힘 |
| E23 | `diff.<d>.command` + `git diff` | 실행됨. `--no-ext-diff --no-textconv`면 실행 안 됨 |
| E24 | `show --numstat`, `diff --stat`, `log --follow`, `stash show --numstat`, `stash show -p` + textconv | 실행 안 됨 (그래도 인자를 붙임) |
| E24a | `log --follow --numstat`(파일 이력, #70)에서 `--no-ext-diff`·`--no-textconv`를 뺌 + `diff=<d>` textconv·`diff.external` (Apple Git 2.54.0, 악성 픽스처의 `*.txt`). 대조군 `log -p`는 textconv 발화 | 실행 안 됨 (그래도 인자를 붙임, SEC-T3-01에 측정으로 고정) |
| E25 | 서브모듈 설정의 fsmonitor + 상위 status | 실행됨. 상위 `-c core.fsmonitor=false`가 전파되어 막힘. `--ignore-submodules=dirty`면 재귀 안 함, gitlink 커밋 변경은 표시됨 |
| E26 | 로컬 `include.path`로 불러온 설정의 scope | `local`로 보고됨. `config.worktree`는 `worktree`, Apple 내장 설정은 `unknown` |
| E27 | `http.sslVerify=false` + `http.<url>.sslVerify=false` (local) | `-c http.sslVerify=true`만으로는 URL별 값이 이김. 같은 URL 키로 덮어야 `true` (`config --get-urlmatch`) |
| E28 | glob 파일명 `d/*`로 `log --` | `--literal-pathspecs`가 없으면 모든 파일과 일치 |
| E29 | `--end-of-options` | `log`, `rev-list`, `diff-tree`, `stash show`, `fetch`, `rev-parse`에서 동작 |
| E30 | `git check-ref-format --branch -- <name>` | `--`를 지원하지 않음 (usage 오류) |
| E31 | NUL이 든 커밋 메시지 (`hash-object --literally`) | `%s`, `%B` 모두 NUL 앞에서 잘림 |
| E32 | `gh auth status --json hosts` | 인증 문제가 있어도 종료 코드 0. 필드: `active, gitProtocol, host, login, scopes, state, tokenSource` |
| E33 | gh 환경 변수 | `GH_TELEMETRY`가 있음 ("Set to false or 0 to disable telemetry") |
| E34 | `remote.origin.url=evilhelper::payload` + canary `git-remote-evilhelper` (PATH에 설치) | 실행됨. `GIT_ALLOW_PROTOCOL=https:ssh:git:file:http`면 `transport 'evilhelper' not allowed` (Apple Git 2.54.0, #161) |
| E35 | E34 + 로컬 `protocol.evilhelper.allow=always` | 환경 변수가 설정보다 우선해 차단. 명령줄 `-c protocol.allow=never`만으로는 실행됨 (이름별 키가 일반 키보다 우선) |
| E36 | https 원격 + `url.evilhelper::x.insteadOf`, 또는 `remote.origin.vcs=evilhelper` | 실행됨. `GIT_ALLOW_PROTOCOL`이면 차단 |
| E37 | `GIT_ALLOW_PROTOCOL` 적용 후 로컬 경로·https·`git+ssh`·scp 형식 원격 | 정상 동작. 목록에서 `file`을 빼면 로컬 경로는 `transport 'file' not allowed`. `https::<url>`은 내장 https로 처리됨 |
| E38 | `1abc::x`, `::x`(빈 이름), `evilhelper://x`, `EvilHelper://x` | 모두 `git-remote-<이름>`이 실행됨(대소문자를 구분하지 않는 볼륨에서는 `EvilHelper`도 `git-remote-evilhelper`를 찾음). `GIT_ALLOW_PROTOCOL`이면 모두 차단. `ftp://`·`ftps://`는 git 내장(curl)이지만 목록에 없어 `transport 'ftp' not allowed` (#191 보안 검토) |
| E39 | 로컬 `trailer.<key>.{cmd,command}`, `trailer.where/ifexists/ifmissing`, `include.path`로 넣은 `trailer.*.command` + 그래프 포맷 `%(trailers:key=Co-authored-by,valueonly,unfold,separator=%x1f)` | 실행 안 됨(pretty 형식은 트레일러를 읽기만 함). 같은 설정에서 `interpret-trailers --trailer`는 실행됨. `trailer.<x>.key`·`trailer.separators`·`core.commentChar`는 어떤 줄이 co-author인지만 바꾼다 (#160 보안 검토) |
| E40 | 로컬 `remote.origin.fetch=+refs/heads/*:refs/heads/*` + detached HEAD, 로컬 `fetch.pruneTags=true`·`remote.origin.pruneTags=true`·`tagOpt=--tags`로 앱 fetch 인자 실행 (Apple Git 2.54.0, #209) | 고정 전: 로컬 전용 브랜치 2개 삭제, `main` 강제 이동, 로컬 태그 삭제. 명령줄 refspec + `--refmap=` + `pruneTags=false`: 로컬 브랜치·태그 불변. `--no-tags`가 없으면 원격 태그 `r1`이 `refs/tags/`에 새로 생김(기존 태그는 그대로). 로컬 `fetch.bundleURI`(평범한 bundle 파일)는 `refs/bundles/heads/*`를 쓰고, `-c fetch.bundleURI=`면 쓰지 않음 |
| E41 | 로컬 `i18n.commitEncoding=JOHAB`(또는 `i18n.logOutputEncoding=JOHAB`) + 제목에 `！`가 든 커밋 + 그래프·커밋 상세·stash 목록 `-z` 포맷 | 일반 실행은 NUL이 늘어 필드가 밀림(그래프 6→8, 상세 2→4, stash 4→5). `-c i18n.logOutputEncoding=UTF-8`이면 정상. UTF-16 설정도 막힘. `for-each-ref`는 영향 없음 (Apple Git 2.54.0, #205) |
| E42 | `clone --filter=blob:none`으로 만든 partial 저장소 + 로컬 `remote.origin.uploadpack` canary에서 `diff-tree -p` (Apple Git 2.50.1, #212) | fetch 목록 환경: canary 실행(lazy fetch). `GIT_NO_LAZY_FETCH=1`: 차단. `GIT_ALLOW_PROTOCOL=`(빈 값)·`=none`: `transport 'file' not allowed`로 차단. `-c remote.origin.promisor=false`·`-c remote.origin.uploadpack=git-upload-pack`: 여전히 실행. 앱의 fetch는 filter 설정이 있는 partial 저장소에서는 lazy fetch를 하지 않음. filter 없이 promisor만 있고 새 객체가 누락 blob을 delta base로 쓰면 fetch도 lazy fetch하며, `GIT_NO_LAZY_FETCH` 없이는 로컬 uploadpack이 실행됨(#213 보안 검토) |
| E43 | 메인 저장소의 `.git/worktrees/forged/gitdir`가 clean filter canary를 둔 다른 저장소를 가리킴 / 연결 워크트리의 `config.worktree`에 filter 드라이버 (Apple Git 2.50.1, #221) | 메인 저장소의 `RepoSafetyContext`로 그 경로의 status를 실행하면 두 경우 모두 canary 실행. 경로별 `probeRepository` 확인(공통 git 디렉터리 비교)과 워크트리별 `configList` 검사를 거치면 실행 안 됨 |
| E44 | git 호환성 매트릭스: git 2.36.6(kernel.org tarball 소스 빌드), Apple Git 2.54.0 (Apple Git-157), Homebrew git 2.54.0으로 INT·SEC를 포함한 전체 테스트 실행. 보조로 2.39.5·2.40.4 (#99, [보고서](../qa/reports/2026-11-08-git-compatibility.md)) | 어느 버전에서도 canary가 실행되지 않음. 차이는 옛 git에 없는 기능(아래 도입 버전)뿐이고, 테스트의 대조군·픽스처만 영향을 받음. 앱 동작 차이는 E45의 오류 분류 하나 |
| E45 | E42의 partial 저장소 + 로컬 `remote.origin.uploadpack` canary에서 blob이 필요한 쿼리(`diff-tree -p` 등)를 앱 환경으로 실행 (git 2.36.6·2.39.5·2.40.4, #99) | 세 버전 모두 canary 실행 안 됨. 2.36.6은 `GIT_NO_LAZY_FETCH`가 없는 git이라 lazy fetch를 시도하고, 빈 `GIT_ALLOW_PROTOCOL`이 막는다. stderr는 `fatal: transport 'file' not allowed`(2회) + `fatal: unable to read <oid>`뿐이다. 2.39.5·2.40.4는 이 변수가 백포트된 버전이라 `warning: lazy fetching disabled …` + `fatal: could not fetch <oid> from promisor remote`를 낸다(2.54.0과 같음). 이 변수는 2024년 5월 보안 릴리스에서 2.44.1과 백포트 2.39.4·2.40.2·2.41.1·2.42.2·2.43.4로 들어왔다. 그러니 "변수가 없는 git"은 2.36–2.44.0 중 백포트가 없는 버전이다(처음 기록의 "2.36–2.43은 무시"는 틀림, #303·#317). 2.36.6 형태는 `GitError`가 `transportNotAllowed`로 잘못 분류했는데, #303에서 `partialCloneObjectMissing`으로 고쳤다 |
| E46 | 로컬 `fetch.bundleURI`(평범한 bundle 파일) + `-c fetch.bundleURI=` 없이 fetch (E40의 대조군, git 2.39.5·2.40.4, #99) | 2.39.5는 키를 무시해 `refs/bundles/*`를 쓰지 않음. 2.40.4부터 씀. 앱의 `-c fetch.bundleURI=`는 두 경우 모두 무해 |
| E47 | 서버가 `uploadpack.advertiseBundleURIs`와 `bundle.*`로 bundle 목록을 광고하고 클라이언트 저장소에 `transfer.bundleURI=true`. 앱 인자 없이 `fetch` (git 2.40.4, 2.45.1, Apple Git 2.54.0, Homebrew 2.54.0) | 네 버전 모두 fetch는 `bundle-uri` 명령을 보내지 않고 `refs/bundles/*`도 없다(`GIT_TRACE_PACKET`). 같은 설정의 `clone`은 bundle을 받는다(2.40.4·Homebrew 2.54.0 trace, Apple 2.54.0 SEC-T13-07 대조군). 덧붙여 2.40.4는 `-c fetch.bundleURI=`(빈 값)에 `failed to download bundle from URI ''` 경고 두 줄만 남기고 fetch는 성공한다. 2.41.0 소스부터 빈 값을 건너뛴다(#195) |

릴리스 노트로 확인한 도입 버전은 다음과 같다. `--end-of-options` 2.24, `config --show-scope` 2.26, `git maintenance` 2.29, `--diff-merges` 2.31, `stash show --include-untracked` 2.32, porcelain v2 `--show-stash` 2.35, `worktree list -z` 2.36, `--attr-source` 2.41. 호환성 매트릭스(#99)에서 테스트에 영향을 준 것은 `fetch.bundleURI` 2.40(E46에서 실측), `worktree add --orphan` 2.42, `GIT_NO_LAZY_FETCH` 2.44, `diff.srcPrefix`·`diff.dstPrefix` 2.45, fetch가 `refs/remotes/<원격>/HEAD`를 자동으로 만드는 동작 2.48이다.

### 4.2 확인하지 못한 것 (추정)

| 항목 | 현재 판단 | 확정 방법 |
|---|---|---|
| 위 동작이 최소 버전 git 2.36에서도 같은지 | **확인됨** (#99, E44–E46): 보안 동작은 같다. 2.36에서 다른 것은 partial clone 쿼리의 오류 분류(#303)뿐이다 | 로컬 매트릭스 실행. CI 매트릭스는 #292 |
| `fetch --no-auto-maintenance` 도입 버전 | 2.29 전후로 추정 | 쓰지 않음 (config로 대체) |
| 실제 HTTPS fetch에서 `sslVerify` 덮어쓰기 효과 | `--get-urlmatch` 결과로 추정 | 자체 서명 인증서 로컬 서버 통합 테스트 (선택) |
| `ssh -o BatchMode=yes`가 호스트 키 확인 프롬프트를 막는지 | ssh 문서상 그렇다고 추정 | 수동 QA |
| unborn 브랜치 워크트리의 `worktree list` 출력 | **확인됨**: `HEAD` 0 OID + `branch` (Apple Git 2.54.0) | PAR-WT-09 (실제 git 테스트 포함) |
| 서브모듈 내부 `filter`가 상위 status에서 실행되는 조건 | **확인됨** (#92): `--ignore-submodules=dirty` 없이 재귀하는 plain status에서 실행된다. 앱의 status는 재귀를 막아 실행되지 않는다 | SEC-T4-05 (대조군 포함) |

---

## 5. 보안 체크리스트

### 5.1 PR용 축약판

PR 템플릿과 `security-reviewer` 에이전트가 쓰는 목록이다.

- [ ] 새 프로세스 실행이 `Overgrove/Execution/` 밖에 없다
- [ ] 새 git·gh 명령이 있다면 [git-command-catalog.md](../architecture/git-command-catalog.md)에 먼저 추가했다
- [ ] 쓰기 명령을 추가하지 않았다 (카탈로그 §7)
- [ ] 저장소·사용자에서 온 값은 OID·전체 ref 검증을 거치거나 `--` 뒤에 있다
- [ ] diff를 만드는 명령에 `--no-ext-diff --no-textconv`가 있다
- [ ] 서명 포맷(`%G...`)을 쓰지 않았다
- [ ] 원격 URL·stderr를 마스킹한 뒤에만 표시·로깅한다
- [ ] 로그에 경로·메시지를 `.private`로 남겼다
- [ ] 환경 변수 allowlist와 공통 보안 인자를 우회하지 않았다
- [ ] 새 외부 의존성이 없다 (있다면 ADR 링크)
- [ ] 해당 위협의 SEC 테스트를 추가하거나 갱신했다

### 5.2 Phase 종료 점검 (전체)

| 항목 | 기준 |
|---|---|
| T1–T19 SEC 테스트 | 전부 통과 (`OvergroveTests/Security`, `OvergroveTests/Integration`) |
| 악성 픽스처 | `scripts/make-fixture-repo.sh --malicious`의 모든 canary가 생성되지 않음 |
| 인자 스냅샷 | 카탈로그와 일치 |
| 금지 API 검사 | 통과 |
| gitleaks | 전체 이력 통과 |
| Actions 고정 | 모든 `uses:`가 SHA로 고정 |
| 잔여 위험 | 이 문서 §2의 잔여 위험을 다시 확인하고 변경 사항을 기록 |

최근 결과: [qa/reports/2026-11-08-security-test-pass.md](../qa/reports/2026-11-08-security-test-pass.md) (#97, `main` `f4259bc`, 전 항목 통과).

---

## 6. S-05 SECURITY 섹션의 표시 근거

워크트리 상세(S-05)의 SECURITY 섹션은 고정 문구가 아니다. **마지막으로 실행한 명령의 실제 최종 인자와 설정 검사 결과**로 표시한다.

| 행 | ✓ (적용됨) | ⚠ (위험 설정 발견 → 무력화됨) | ✕ (확인 불가) |
|---|---|---|---|
| Hooks disabled | 최종 인자에 `-c core.hooksPath=/dev/null` 있음 | 로컬 `core.hooksPath`가 있거나 `.git/hooks`에 `.sample`이 아닌 실행 파일이 있음 | 설정 검사 실패 |
| fsmonitor disabled | `-c core.fsmonitor=false` 있음 | 로컬 `core.fsmonitor` 발견 | 설정 검사 실패 |
| External diff / textconv disabled | 카탈로그상 diff case에 인자 있음 (스냅샷 테스트로 보증) | 로컬 `diff.*` 드라이버 발견 | — |
| Filters neutralized | 로컬 필터 없음 | 무력화한 드라이버 이름 목록 | 드라이버 이름 형식 위반 → 조회 중단 |
| Transport commands neutralized | 로컬 `sshCommand`·`gitProxy`·`uploadpack`·`ext::` 원격 없음 | 발견한 키 목록 (무력화됨) | — |
| Credential helpers (repo-local) ignored | 로컬 helper 없음 | 로컬 helper 발견 → fetch에서 제외 | — |
| TLS verification | 로컬 `sslVerify=false` 없음 | 발견 → fetch에서 `true`로 복원 | — |
| Remote URL credentials masked | 원격 URL에 자격 증명 없음 | 자격 증명 포함 원격 발견 → 마스킹 표시, 제거 권장 | — |

- 섹션 머리에 설정 검사 시각과 검사 대상 scope(`local`, `worktree`)를 표시한다.
- ⚠ 항목은 펼치면 키 이름을 보여 준다. 값은 보여 주지 않는다 (명령 문자열에 비밀이 있을 수 있음).
- ✕가 하나라도 있으면 해당 저장소의 조회는 이미 중단된 상태다. 섹션 상단에 원인을 보여 준다.
