# 보안 검토 (위협 모델)

> 상태: Accepted (Phase 2 게이트, 2026-11-05) · 관련: ADR-0004, ADR-0006, ADR-0008, ADR-0009, [../architecture/git-command-catalog.md](../architecture/git-command-catalog.md), [../architecture/overview.md](../architecture/overview.md)

Overgrove는 **사용자가 고른 로컬 저장소에 대해 시스템 `git`을 실행하는 앱**이다. 저장소는 신뢰할 수 없다고 가정한다. 예를 들어 처음 클론한 오픈소스, 받은 압축 파일, AI 에이전트가 만든 워크트리일 수 있다. 이 문서는 위협 T1–T18 각각에 대해 시나리오, 대응, 잔여 위험, 검증 테스트를 정의한다.

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
| macOS, `/usr/bin/git`(Apple 서명), 사용자가 설치한 `gh` | 저장소 안의 모든 것: 작업 트리 파일, `.gitattributes`, `.gitmodules` |
| git의 `system`, `global`, `unknown`(Apple 내장), `command` scope 설정 | `.git/config`(`local`), `config.worktree`(`worktree`), 그 설정이 include한 파일 |
| 사용자가 `NSOpenPanel`로 고른 경로 | `.git/info/attributes`, `.git/hooks/*`, 서브모듈의 `.git/modules/*/config` |
| | 원격 서버 응답, 원격 저장소 내용 |

global 설정이나 사용자 홈 디렉터리를 악성 코드가 바꾸는 경우는 이 앱의 위협 모델 밖이다. 그 상태라면 이미 계정이 장악된 것이다.

### 1.3 공격자 모델

- 저장소 파일과 `.git` 디렉터리 내용을 마음대로 만들 수 있다 (악성 저장소를 배포하는 공격자).
- 원격 서버를 운영할 수 있다 (악성 원격).
- 사용자를 속여 앱에 저장소를 등록하게 할 수 있다.
- 사용자 계정의 global 설정과 앱 바이너리는 바꿀 수 없다.

---

## 2. 위협별 분석

상태 표기: **설계 완료**는 대응이 정의되어 있고 구현 전이라는 뜻이다. **적용됨**은 저장소 셋업에서 이미 적용했다는 뜻이다. **확인**은 Apple Git 2.50.1 실험(§4)으로 검증한 사실이다.

### T1. `core.fsmonitor` 실행

- **설명**: `core.fsmonitor`에 실행 파일 경로를 넣으면 `git status`가 그 프로그램을 실행한다.
- **시나리오**: 악성 저장소의 `.git/config`에 `core.fsmonitor = ./.git/evil`. 사용자가 앱에 등록하는 순간 status 조회로 실행된다. 서브모듈의 설정에 넣어도 상위 저장소 status가 서브모듈로 재귀하며 실행된다 (확인).
- **대응**:
  - 공통 인자 `-c core.fsmonitor=false` (확인: 실행 안 됨). `-c`는 `GIT_CONFIG_PARAMETERS`로 서브프로세스(서브모듈)에도 전파된다 (확인).
  - status에 `--ignore-submodules=dirty`를 붙여 서브모듈 재귀 자체를 막는다 (확인).
  - `RepoConfigInspector`가 탐지해 S-05에 "무력화됨"으로 보고한다.
- **잔여 위험**: 없음 (확인된 범위). 내장 fsmonitor 데몬(`core.fsmonitor=true`)도 함께 꺼진다. 대신 큰 저장소의 status가 느려질 수 있다 (PB-5 측정).
- **검증**: SEC-T1-01 (악성 픽스처 status → canary 없음), SEC-T1-02 (서브모듈 fsmonitor → canary 없음), SEC-T1-03 (모든 명령의 인자 스냅샷에 포함)
- **상태**: 설계 완료

### T2. hooks 실행

- **설명**: `.git/hooks/*` 또는 `core.hooksPath`가 가리키는 훅이 실행된다. 조회 명령은 대부분 훅을 실행하지 않지만, **fetch는 ref를 갱신할 때 `reference-transaction` 훅을 실행한다** (확인).
- **시나리오**: 악성 저장소에 `.git/hooks/reference-transaction` 실행 파일이 있다. 사용자가 Fetch 버튼을 누르면 실행된다.
- **대응**: 공통 인자 `-c core.hooksPath=/dev/null`. 훅 디렉터리가 존재하지 않는 경로가 되어 실행되지 않는다 (확인). 로컬 `core.hooksPath`보다 명령줄이 우선한다.
- **잔여 위험**: 없음 (확인된 범위).
- **검증**: SEC-T2-01 (훅이 든 픽스처 fetch → canary 없음), SEC-T2-02 (인자 스냅샷)
- **상태**: 설계 완료

### T3. 외부 diff, textconv 실행

- **설명**: `.gitattributes`의 `diff=<driver>`와 설정의 `diff.<driver>.textconv`·`diff.<driver>.command`, 또는 `diff.external`이 diff를 만들 때 실행된다.
  - `git diff`는 기본으로 외부 diff 드라이버를 실행한다 (확인).
  - `git show -p`는 textconv를 실행한다 (확인).
- **시나리오**: 사용자가 파일 diff를 열면 악성 textconv가 실행된다.
- **대응**:
  - diff를 만드는 모든 명령(`diff`, `diff-tree -p`, `stash show -p`)에 `--no-ext-diff --no-textconv`를 붙인다 (확인: 실행 안 됨).
  - numstat 계열(`diff-tree --numstat`, `stash show --numstat`)은 실험에서 textconv를 부르지 않았다. 그래도 같은 인자를 붙인다.
- **잔여 위험**: 새 diff 명령을 추가할 때 인자를 빠뜨릴 수 있다. 그래서 카탈로그의 모든 diff case를 SEC-T3-02가 열거해 검사한다.
- **검증**: SEC-T3-01 (textconv, `diff.<d>.command`, `diff.external` 픽스처 → canary 없음), SEC-T3-02 (diff 계열 case 전수 인자 검사)
- **상태**: 설계 완료

### T4. clean/smudge/process 필터 실행

- **설명**: `filter=<driver>` 속성이 붙은 파일의 stat 정보가 index와 다르면, `git status`가 내용을 비교하려고 clean 필터를 실행한다 (확인).
  - `--no-optional-locks`면 index를 갱신하지 않으므로 **status를 부를 때마다 다시 실행된다** (확인).
  - 속성은 트리의 `.gitattributes`뿐 아니라 `.git/info/attributes`에서도 온다.
  - 드라이버 이름이 임의라서 고정된 `-c`로는 막을 수 없다.
- **시나리오**: 악성 저장소에 `* filter=x`와 `filter.x.clean = <명령>`이 있다. 등록 직후 status 조회로 실행된다.
- **대응** (ADR-0009):
  - `RepoConfigInspector`가 `local`·`worktree` scope의 `filter.<d>.*`를 찾아, 드라이버마다 `-c filter.<d>.clean= -c filter.<d>.smudge= -c filter.<d>.process= -c filter.<d>.required=false`를 붙인다.
    - 빈 clean은 필터를 끈다 (확인).
    - `required=true`인 상태에서 clean만 비우면 fatal이 난다 (확인, E6). 그래서 `required=false`를 함께 넣는다. SEC-T4-03이 이 사실(무력화에서 `required=false`만 빼면 status 실패)을 고정한다. 내용이 바뀐 파일은 status가 다시 해시하지 않아 이 오류가 나지 않으므로, 내용은 같고 stat만 바뀐 파일로 확인해야 한다.
  - 드라이버 이름이 허용 형식이 아니면 fail closed.
  - 서브모듈 쪽 필터는 `--ignore-submodules=dirty`로 재귀를 막아 차단한다.
- **대안 검토**: `--attr-source=<empty tree>`(git 2.41+)는 트리의 `.gitattributes`만 막고 `.git/info/attributes`는 막지 못한다 (확인). 주 대응이 될 수 없다.
- **잔여 위험**:
  - global 설정에 정의된 필터(예: 사용자가 설치한 Git LFS)는 신뢰 범위라 그대로 실행된다. 의도된 동작이다.
  - 로컬에 정의된 LFS 필터를 무력화하면 LFS 파일이 변경으로 보일 수 있다.
- **검증**: SEC-T4-01 (`.gitattributes` 필터 → canary 없음), SEC-T4-02 (`.git/info/attributes` 필터), SEC-T4-03 (`required=true`여도 status 성공), SEC-T4-04 (허용 밖 드라이버 이름 → 조회 차단), SEC-T4-05 (서브모듈 필터), SEC-T4-06 (그래프 포맷의 `%(trailers)`가 로컬 `trailer.<key>.cmd`/`.command`를 실행하지 않음, #160)
- **상태**: 설계 완료

### T5. 전송 계층 명령 실행

- **설명**: fetch가 원격에 연결할 때 다음 경로로 임의 명령이 실행된다. 모두 확인했다.

  | 경로 | 확인 결과 |
  |---|---|
  | 로컬 `core.sshCommand` | ssh 원격 fetch 시 실행 |
  | 로컬 `core.gitProxy` | `git://` 원격 fetch 시 실행. `-c core.gitProxy=`로는 막히지 않음 |
  | 로컬 `remote.<n>.uploadpack` | 로컬 경로 원격 fetch 시 실행. `-c remote.<n>.uploadpack=...`로는 막히지 않음 (첫 값이 이김) |
  | `ext::<명령>` URL + 로컬 `protocol.ext.allow=always` | 실행. `url.<base>.insteadOf`로 평범한 https URL을 `ext::`로 바꿔치기해도 실행 |
  | `fd::` URL | 기본 허용이며 fetch가 정지함 |
  | 로컬 `core.alternateRefsCommand` + `objects/info/alternates` | alternates가 있는 저장소의 fetch에서 실행 (테스트 fork 실측, [fixtures.md §8](../testing/fixtures.md)) |
  | `<helper>::<주소>` URL, git이 직접 처리하지 않는 `<scheme>://` URL, `remote.<n>.vcs`, `insteadOf`로 바꿔치기한 URL | 사용자가 설치한 `git-remote-<helper>`(`hg`, `gcrypt`, `codecommit` 등)를 **저장소가 고른 인자로** 실행. 로컬 `protocol.<helper>.allow=always`가 있으면 명령줄 `-c protocol.allow=never`로도 막히지 않음 (이름별 키가 일반 키보다 우선, #161 실측) |
  | **조회 명령의 lazy fetch** (partial clone: 로컬 `remote.<n>.promisor`·`partialclonefilter` 또는 처음부터 partial로 배포된 저장소) | 내용이 필요한 조회(diff, numstat, `log --follow`)가 누락 객체를 promisor 원격에서 가져오며 로컬 `remote.<n>.uploadpack`을 실행. https 원격이면 401 뒤 로컬 `credential.helper`도 실행. 조회에는 fetch의 `--upload-pack` 고정·인증 재설정이 없음 (#210 보안 검토, #212 실측) |

- **시나리오**: 사용자가 Fetch를 누르면 원격 설정에 숨긴 명령이 실행된다.
- **대응**:
  - **환경 변수 `GIT_SSH_COMMAND`**: 신뢰 scope의 `core.sshCommand`, 없으면 `ssh -o BatchMode=yes`. 환경 변수가 로컬 설정보다 우선한다 (확인). 빈 `-c core.sshCommand=`는 ssh 자체를 망가뜨려서 쓰지 않는다 (확인).
  - **환경 변수 `GIT_PROXY_COMMAND=`(빈 값)**: 로컬 `core.gitProxy` 무력화 (확인).
  - **`fetch --upload-pack=git-upload-pack`**: 로컬 uploadpack 무력화 (확인).
  - **환경 변수 `GIT_ALLOW_PROTOCOL=https:ssh:git:file:http`**: 내장 전송만 허용한다. `protocol.allow=never`에 목록의 전송만 `always`로 둔 것처럼 동작하고, 저장소의 `protocol.<이름>.allow=always`를 포함한 모든 설정보다 우선한다. 저장소가 고른 원격 helper(`<helper>::` URL, `remote.<n>.vcs`, `insteadOf` 바꿔치기)는 `transport '<이름>' not allowed`로 실행 전에 거부된다 (확인, E34–E38). 거부는 `GitError.transportNotAllowed`로 분류해 이유를 보여 준다.
  - **조회는 전송을 쓰지 않는다(#212)**: `GitClient.run`의 환경은 `GIT_ALLOW_PROTOCOL=`(빈 값)이다. 빈 목록은 모든 전송을 원격 helper·uploadpack·credential helper 실행 전에 거부한다(`transport 'file' not allowed`, 확인 E41). git의 protocol policy(2.12+)라서 최소 지원 2.36부터 모든 버전에 적용된다(소스 기준, 2.36–2.43은 직접 실행하지 못함). 모든 명령에 `GIT_NO_LAZY_FETCH=1`(2.44+, 그 전에는 무시됨)을 두 번째 층으로 둔다. `-c remote.<n>.promisor=false`와 `-c remote.<n>.uploadpack=…`로는 막히지 않는다(로컬 값이 이김, 확인). fetch만 `https:ssh:git:file:http` 목록을 쓴다.
  - **공통 인자 `-c protocol.ext.allow=never -c protocol.fd.allow=never`**: `ext::`와 `insteadOf` 바꿔치기, `fd::` 차단 (확인). `GIT_ALLOW_PROTOCOL`과 겹치지만 심층 방어로 유지한다.
  - **공통 인자 `-c core.alternateRefsCommand=`(빈 값)**: alternates 경로 무력화. 빈 값이어도 fetch는 성공한다 (확인).
  - fetch는 `--no-recurse-submodules`로 서브모듈 원격에 연결하지 않는다.
- **잔여 위험**:
  - 로컬 경로 원격(`file://` 또는 경로)을 fetch하면, **상대 저장소**에서 `git-upload-pack`이 실행되면서 그 저장소의 설정을 읽는다. 상대 저장소의 설정은 검사하지 않는다. v0.2.0의 "신뢰하지 않음 모드"(#107)에서는 `GIT_ALLOW_PROTOCOL` 목록에서 `file`을 빼는 방식으로 막을 수 있다 (`transport 'file' not allowed`, 확인).
  - `ftp://`·`ftps://` 원격도 목록에 없어 fetch할 수 없다. git 내장 전송이지만 거의 쓰이지 않아 감수한다.
  - 커스텀 원격 helper(`codecommit::` 등)를 쓰는 원격은 v0.1에서 fetch할 수 없다. 허용이 필요해지면 저장소 설정이 아니라 앱 설정(사용자 선택)으로만 연다 (v0.1 범위 밖).
  - 사용자가 global에 정의한 `core.gitProxy`는 v0.1에서 무시된다 (빈 `GIT_PROXY_COMMAND`). `git://` 프로토콜은 드물어서 감수한다.
  - **터미널로 보내는 안내.** fetch 실패 안내(`FetchFailureGuidance`, #78)가 사용자를 터미널로 보내면, 터미널의 git은 이 문서의 대응을 하나도 적용받지 않는다. 악성 저장소가 일부러 fetch를 실패시켜(예: 처음 보는 호스트로 `hostKeyNotTrusted`) 사용자가 페이로드를 직접 실행하게 만들 수 있다(#200 보안 검토).
    - 그래서 `git` 명령은 `RepoSecurityReport`에 항목이 없을 때만 복사용으로 제시하고, 그때도 "신뢰하는 저장소에서만"이라고 쓴다.
    - 항목이 있으면 저장소를 읽지 않는 명령(`ssh-add -l`, `ssh-keyscan … | ssh-keygen -lf -`, `ssh-keygen -F`)만 제시한다.
    - 남는 위험: `.git/hooks`와 `pager.*`는 설정 보고에 나오지 않으므로, 보고가 깨끗해도 터미널 git이 이것들을 실행할 수 있다. 안내 문구가 이를 경고한다.
- **검증**: SEC-T5-01 (sshCommand), SEC-T5-02 (uploadpack, 로컬 원격), SEC-T5-03 (`ext::`), SEC-T5-04 (`insteadOf` → `ext::`), SEC-T5-05 (gitProxy), SEC-T5-06 (`fd::` 차단, 정지 없음), SEC-T5-07 (alternates 저장소 fetch에서 `alternateRefsCommand` canary 미생성), SEC-T5-08 (`<helper>::` URL), SEC-T5-09 (로컬 `protocol.<helper>.allow=always`), SEC-T5-10 (`insteadOf` → `<helper>::`), SEC-T5-11 (`remote.<n>.vcs`), SEC-T5-12 (명령줄 `-c protocol.allow=never`로는 부족함), SEC-T5-13 (로컬 경로 원격은 계속 허용), SEC-T5-14 (https는 전송 정책으로 거부되지 않음), SEC-T5-15 (git이 직접 처리하지 않는 `<scheme>://` URL), SEC-T5-16 (이미 partial인 저장소 + 로컬 uploadpack canary: 앱 조회(`commitPatch`, `commitFiles`, `fileHistory`) 뒤 canary 없음, 대조군(#212 이전 환경)은 실행)
- **상태**: 설계 완료

### T6. 저장소 로컬 `credential.helper` 실행

- **설명**: 원격 인증이 필요할 때 git은 system → global → local 순서로 쌓인 credential helper를 차례로 실행한다. 앞선 helper가 자격 증명을 주지 못하면 로컬 helper까지 실행된다 (확인). URL별 키(`credential.<url>.helper`)도 같다.
- **시나리오**: 악성 저장소의 `credential.helper = !<명령>`이 fetch 인증 과정에서 실행된다. 자격 증명을 가로채는 helper도 만들 수 있다.
- **대응** (ADR-0009):
  1. fetch에 `-c credential.helper=`(빈 값)을 넣어 그때까지 쌓인 목록을 비운다. URL별 helper도 함께 비워진다 (확인).
  2. 그 뒤에 신뢰 scope의 `credential.*helper` 항목을 **원래 순서와 키 그대로** 다시 넣는다. Apple 내장 `osxkeychain`과 `gh auth setup-git` 형식의 URL별 항목이 이렇게 복원된다 (확인).
  3. 순서가 중요하다. URL별 빈 값을 신뢰 helper보다 뒤에 넣으면 신뢰 helper까지 지워진다 (확인). 그래서 항상 "초기화 → 재삽입" 순서를 지킨다.
- **잔여 위험**: 신뢰 scope의 helper 자체가 위험하면 막지 못한다 (위협 모델 밖).
- **검증**: SEC-T6-01 (로컬 generic helper → canary 없음), SEC-T6-02 (로컬 URL별·와일드카드 helper → canary 없음), SEC-T6-03 (신뢰 global helper와 URL별 helper가 순서대로 실행됨), SEC-T6-04 (https promisor 원격의 lazy fetch: 앱 조회는 로컬 helper를 실행하지 않고 서버에 요청도 보내지 않음, 대조군은 401 뒤 helper 실행, #212)
- **상태**: 설계 완료

### T7. 서명 검증 프로그램 실행

- **설명**: 서명 관련 log 포맷(`%G?` 등)을 쓰거나 로컬 `log.showSignature=true`가 있으면, `git log`와 `git show`가 `gpg.program`(또는 `gpg.ssh.program`)을 실행한다. 서명된 커밋이 하나라도 있으면 실행된다 (확인).
- **시나리오**: 악성 저장소가 가짜 서명 커밋 하나와 로컬 `gpg.program = <명령>`, `log.showSignature = true`를 둔다. 그래프를 여는 순간 실행된다.
- **대응**:
  - 공통 인자 `-c log.showSignature=false` (확인: 실행 안 됨)
  - 서명 포맷(`%G?`, `%GS`, `%GK`, `%GF`, `%GP`, `%GT`) 사용 금지. 카탈로그 리뷰와 정적 검사로 막는다.
  - 서명 표시 기능은 범위 밖이다.
- **잔여 위험**: 없음 (확인된 범위).
- **검증**: SEC-T7-01 (악성 픽스처에서 graphPage, commitMeta, fileHistory → canary 없음), SEC-T7-02 (소스에 `%G` 포맷 문자열이 없음을 검사)
- **상태**: 설계 완료

### T8. fetch 중 자동 gc·maintenance

- **설명**: fetch가 끝나면 git이 `git maintenance run --auto`를 실행한다 (확인: `GIT_TRACE`). 이 작업은 객체를 다시 묶고 prune하는 쓰기 작업이고, 큰 저장소에서 오래 걸린다.
- **시나리오**: 조회 앱이 사용자 모르게 저장소 정리를 시작한다. 그동안 사용자의 다른 git 작업과 잠금이 충돌한다.
- **대응**: 공통 인자 `-c gc.auto=0 -c maintenance.auto=false` (확인: maintenance가 실행되지 않음). fetch의 `--no-auto-maintenance` 옵션도 2.50에서는 받아들여지지만, 도입 버전을 확인하지 못해 쓰지 않는다.
- **잔여 위험**: 없음.
- **검증**: SEC-T8-01 (로컬 `gc.auto=1`·`maintenance.auto=true` 픽스처를 `GIT_TRACE=1`로 fetch했을 때 자식 프로세스에 `maintenance run`과 `gc --auto`가 없음. pack 수 비교는 alternates가 있으면 변하지 않아 판정에 쓰지 않는다, [fixtures.md §8.3](../testing/fixtures.md)), SEC-T8-02 (인자 스냅샷)
- **상태**: 설계 완료

### T9. 인자 인젝션

- **설명**: 파일명이나 ref 이름이 옵션(`--output=...`)이나 pathspec 매직(`:(exclude)`, glob `*`)으로 해석되는 문제다.
- **시나리오**: `--output=../../x`라는 이름의 파일이나 ref를 인자로 넘기면 git이 파일을 쓴다. `*`라는 파일명의 이력을 보면 glob으로 해석되어 다른 파일 이력이 섞인다 (확인: glob이 모든 파일과 일치).
- **대응**:
  1. 셸을 쓰지 않는다. 인자는 배열로만 넘긴다 (ADR-0008).
  2. 경로는 항상 `--` 뒤에 둔다.
  3. 공통 인자 `--literal-pathspecs`로 pathspec 매직을 끈다 (확인).
  4. 커밋은 검증된 OID(`^[0-9a-f]{40}$|^[0-9a-f]{64}$`)로만 가리킨다. stash도 `stash@{n}`이 아니라 OID로 가리킨다.
  5. ref는 `refs/`로 시작하는 전체 이름만 인자로 쓴다. 제어 문자, 공백, `..`, `-` 시작 구성 요소가 있으면 거부한다.
  6. 리비전 인자 앞에 `--end-of-options`를 둔다. `log`, `rev-list`, `diff-tree`, `stash show`, `fetch`에서 동작을 확인했다.
  7. `git check-ref-format`은 `--` 구분자를 지원하지 않아(확인) 검증에 쓰지 않는다. 검증은 앱 코드에서 한다.
- **잔여 위험**: 낮음. 모든 인자는 git 출력에서 온 값이고, 사용자가 직접 입력하는 값(검색어)은 git에 넘기지 않는다.
- **검증**: SEC-T9-01 (모든 case의 최종 인자 배열 스냅샷), SEC-T9-02 (ref 검증: `-x`, `refs/heads/a..b`, 제어 문자 거부), SEC-T9-03 (파일명 `-x`, `--output=x`, `:(exclude)x`, `*`로 diff·이력 → 해당 파일만 대상, 부수 파일 생성 없음), SEC-T9-04 (OID 검증)
- **상태**: 설계 완료

### T10. 부모 환경 변수 상속

- **설명**: 앱을 터미널에서 실행하면 `GIT_DIR`, `GIT_CONFIG_PARAMETERS`, `GIT_SSH_COMMAND`, `GIT_EXTERNAL_DIFF`, `GIT_EXEC_PATH`, `DYLD_*` 같은 변수가 상속되어 git 동작이 바뀐다.
- **시나리오**: 다른 도구가 설정한 `GIT_DIR` 때문에 엉뚱한 저장소를 조회한다. `GIT_EXTERNAL_DIFF`가 의도치 않은 프로그램을 실행한다.
- **대응**: 환경 변수를 allowlist로 새로 만든다 (§3.2). 부모 환경은 `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SSH_AUTH_SOCK`만 전달한다. PATH는 고정값이다. 페이저는 `--no-pager`와 `GIT_PAGER=cat`으로 이중 차단한다. gh는 별도 allowlist(`HOME`, `USER`, `TMPDIR`와 고정값, [카탈로그 §5](../architecture/git-command-catalog.md))를 쓴다. `GH_TOKEN`, `GITHUB_TOKEN`, `GH_HOST`, `GH_REPO`, `GH_CONFIG_DIR`, 브라우저·편집기 변수는 gh에 전달하지 않는다.
- **잔여 위험**: 사용자의 셸 설정에 의존하던 git 동작(예: 셸에서만 설정한 `GIT_SSH_COMMAND`)은 앱에서 동작하지 않는다. 의도된 동작이고 문서화한다. `HOME`은 부모 값을 그대로 쓰므로, 앱 실행 환경을 바꿀 수 있는 같은 사용자는 git·gh가 읽는 전역 설정(`~/.gitconfig`, `~/.config/gh`)과 gh 계정 선택을 바꿀 수 있다. 이 권한은 원래 신뢰 경계 밖이다. gh 실행 파일은 경로를 탐색한 뒤 `posix_spawn`이 다시 해석하므로(TOCTOU), 그 사이에 `/opt/homebrew/bin`에 쓸 수 있는 사용자는 실행 파일을 바꿀 수 있다. 위협 모델은 사용자가 설치한 gh를 신뢰하므로(§1) 받아들인다.
- **검증**: SEC-T10-01 (테스트 프로세스 환경에 위험 변수를 넣어도 자식 프로세스 환경에 없음), SEC-T10-02 (PATH 고정), SEC-T10-03 (gh 자식 환경이 카탈로그 §5 allowlist와 정확히 같음. 토큰·호스트·설정 디렉터리 변수 없음, 텔레메트리 끔)
- **상태**: 설계 완료

### T11. 자격 증명 노출

- **설명**: 원격 URL에 `https://user:token@host/...`처럼 자격 증명이 들어 있을 수 있다. 이것이 화면, 로그, 에러 메시지(stderr)로 새어 나갈 수 있다. 또 로컬 설정의 `http.sslVerify=false`는 TLS 검증을 꺼서 중간자에게 자격 증명을 넘길 수 있다.
- **대응**:
  - **`CredentialMasker`**: 아래 패턴을 `***`로 바꾼다. 화면 표시, 로그, 에러 요약 전에 반드시 거친다.
    - URL userinfo (`scheme://user:pass@` → `scheme://***@`, `scheme://token@` → `scheme://***@`)
    - 쿼리 파라미터 `access_token=`, `token=`
    - GitHub 토큰 접두사 `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`
    - `Authorization:` 헤더 줄
  - **원격 URL 표시**: 기본은 마스킹이다. 설정의 "원격 URL 표시"를 켜도 자격 증명 부분은 계속 마스킹한다. 원격 URL에 자격 증명이 들어 있으면 S-05에 경고하고, credential helper 사용을 권장한다.
  - **TLS 설정**: `local`·`worktree` scope에서 `false`로 설정된 `http.sslVerify`·`http.<url>.sslVerify`를 fetch에서 같은 키의 `true`로 덮는다 (확인: `config --get-urlmatch`). 로컬 `http.*proxy`는 신뢰 scope 값(없으면 빈 값)으로 덮고, 로컬 `http.*sslCAInfo`·`sslCAPath`·`sslCert`·`sslKey`가 있으면 fetch를 막는다(§3.3, #150).
  - 앱은 토큰을 받거나 저장하지 않는다. `gh auth status`는 `--show-token` 없이 호출한다.
- **잔여 위험**: 새로운 토큰 형식은 마스킹 패턴에 없을 수 있다. URL userinfo는 형식과 관계없이 전부 마스킹하므로 위험이 줄어든다.
- **검증**: SEC-T11-01 (`CredentialMasker` 단위 테스트), SEC-T11-02 (fetch 실패 stderr가 마스킹된 뒤에만 UI 모델과 로그에 들어감), SEC-T11-03 (로컬 `sslVerify=false` → 최종 인자로 `true` 복원), SEC-T11-04 (S-05, 상태바의 원격 표시가 마스킹됨), SEC-T11-05 (`GHCommand`의 어떤 인자에도 token이 없고, gh stderr는 마스킹된 뒤에만 `GHError`에 들어감)
- **상태**: 설계 완료

### T12. 자격 증명 프롬프트 대기

- **설명**: 백그라운드 fetch가 사용자 이름·비밀번호·호스트 키 확인을 기다리며 멈출 수 있다. 로컬 `core.askPass`는 `GIT_TERMINAL_PROMPT=0`이어도 실행된다 (확인).
- **대응**:
  - 환경 변수 `GIT_TERMINAL_PROMPT=0`
  - 빈 `GIT_ASKPASS`와 빈 `SSH_ASKPASS`. 빈 `GIT_ASKPASS`는 `core.askPass`보다 우선해 실행을 막는다 (확인).
  - 공통 인자 `-c core.askPass=` (확인)
  - ssh는 `-o BatchMode=yes`로 프롬프트 없이 실패하게 한다. 신뢰 scope의 `core.sshCommand`가 있으면 그 값을 존중한다.
  - fetch 타임아웃은 120초다.
  - 인증 실패는 stderr 패턴으로 분류해 터미널에서 확인하라고 안내한다.
- **잔여 위험**: 신뢰 scope의 사용자 지정 sshCommand에 BatchMode가 없으면 호스트 키 확인에서 멈출 수 있다. 이 경우 타임아웃으로 끊긴다.
- **검증**: SEC-T12-01 (로컬 askPass → canary 없음, 즉시 실패), SEC-T12-02 (인증이 필요한 원격에서 helper가 없으면 `authenticationFailed`로 빠르게 실패)
- **상태**: 설계 완료

### T13. 의도치 않은 쓰기 명령 실행

- **설명**: 조회 앱이 버그나 잘못된 구현으로 쓰기 명령을 실행하는 문제다.
- **대응**:
  - **컴파일 타임 allowlist**: `ReadOnlyGitCommand`와 `FetchCommand` case만 존재한다. 쓰기 명령은 타입이 없다 ([카탈로그 §7](../architecture/git-command-catalog.md)).
  - **프로세스 생성 위치 제한**: `Overgrove/Execution/` 밖에서 `Process`를 만들면 안 된다. `scripts/lint/check-forbidden-apis.sh`가 pre-commit hook, Claude Code hook, CI에서 검사한다.
  - **index 쓰기 방지**: `--no-optional-locks`와 `GIT_OPTIONAL_LOCKS=0`으로 조회 중 `index.lock`을 잡지 않는다.
  - **허용된 쓰기**: fetch가 만드는 쓰기(`refs/remotes/<원격>/*`, `FETCH_HEAD`, 객체)와 `--prune`의 원격 추적 ref 삭제뿐이다.
  - **fetch 범위 고정(#209)**: 저장소 설정이 이 범위를 넓히지 못하게 fetch 인자에 고정한다. refspec `+refs/heads/*:refs/remotes/<원격>/*`와 `--refmap=`, `--no-tags`, `-c fetch.pruneTags=false -c remote.<원격>.pruneTags=false -c fetch.bundleURI=`를 쓴다([카탈로그 §4](../architecture/git-command-catalog.md)). 고정하기 전에는 로컬 `remote.<n>.fetch=+refs/heads/*:refs/heads/*`(detached HEAD)가 로컬 브랜치를 지우고 `main`을 되돌렸다. 로컬 `fetch.pruneTags`는 로컬 태그를 지웠다(#206 보안 검토, E40).
- **잔여 위험**: 낮음.
  - **`worktreeDiff`(`git diff`)는 내용은 같고 stat만 바뀐 파일을 diff할 때 index를 새로 고쳐 쓴다** (#208). `--no-optional-locks`와 `GIT_OPTIONAL_LOCKS=0`을 무시한다(Apple Git 2.50.1 실측). 잠깐 `index.lock`을 잡으므로 같은 순간 사용자의 git 쓰기 명령과 겹칠 수 있다. `-c diff.autoRefreshIndex=false`로 막힌다(실측). `WriteProtectionTests`가 expected failure로 추적한다.
  - `--no-tags` 때문에 원격에만 있는 새 태그는 v0.1에서 가져오지 않는다(의도된 동작, #209).
- **검증**: SEC-T13-01 (모든 case의 서브커맨드가 허용 집합 안에 있음), SEC-T13-02 (status 조회 전후 `.git/index` 내용·mtime 불변, 연결 워크트리 포함. 다른 조회는 `.git` 전체 불변까지 확인), SEC-T13-03 (금지 API 정적 검사. 저장소 전체 통과와 함께, 심은 위반을 실제로 거부하는지 테스트로 확인), SEC-T13-04 (로컬 `remote.<n>.fetch`·`fetch.pruneTags`·`remote.<n>.pruneTags`·`tagOpt`·`fetch.bundleURI`를 심은 저장소에서 앱 fetch 뒤 `refs/remotes/` 밖의 모든 ref와 HEAD 불변, 대조군(고정 전 인자)에서는 브랜치·태그 삭제, `main` 이동, `refs/bundles/*` 생성)
- **상태**: 설계 완료 (정적 검사 스크립트는 저장소 셋업에서 적용)

### T14. 파일 시스템 범위 이탈, 심볼릭 링크 탈출

- **설명**: 심볼릭 링크나 `core.worktree` 설정, 조작된 `.git` 파일이 저장소 밖의 파일을 읽게 만들 수 있다.
- **시나리오**:
  - untracked 파일 미리보기가 `~/.ssh/id_ed25519`를 가리키는 심볼릭 링크를 따라가 내용을 보여 준다.
  - 로컬 `core.worktree`가 홈 디렉터리를 가리켜 status가 홈 전체를 훑는다.
- **대응**:
  - 저장소는 `NSOpenPanel`로 고른 경로만 등록한다.
  - `PathValidator`가 경로를 정규화하고 심볼릭 링크를 해석한 결과를 비교한다. 고른 경로와 다르면 경고한다.
  - untracked 미리보기는 해석한 실제 경로가 워크트리 안일 때만 실행한다. 심볼릭 링크는 링크 대상 문자열만 보여 준다.
  - 로컬 `core.worktree`는 경고로 보고한다.
  - 연결 워크트리는 그 안의 `.git` 파일이 이 저장소의 `worktrees/<name>`을 가리키는지 확인한다.
- **잔여 위험**: git 자체가 따라가는 경로(예: alternates 객체 저장소)는 통제하지 않는다. 읽기 전용이라 영향이 제한적이다.
- **검증**: SEC-T14-01 (심볼릭 링크 등록 경로 경고), SEC-T14-02 (저장소 밖을 가리키는 untracked 심볼릭 링크는 링크 문자열만 미리보기하고 대상 내용은 보이지 않음, 상위 디렉터리가 밖으로 나가는 경로는 거부), SEC-T14-03 (로컬 `core.worktree` 보고)
- **상태**: 설계 완료

### T15. 자원 고갈

- **설명**: 병적인 저장소(거대한 출력, 수백만 개 파일, 끝나지 않는 원격)가 메모리를 고갈시키거나 앱을 멈추게 할 수 있다. `fd::` 원격은 fetch를 정지시켰다 (확인).
- **대응**:
  - 타임아웃: 기본 15초, fetch 120초. SIGTERM 뒤 2초가 지나면 SIGKILL.
  - stdout 상한 10MB(fetch 1MB), stderr 상한 64KB(fetch 256KB). 넘으면 읽기를 멈추고 `truncated` 결과를 돌려준다.
  - 동시 git 프로세스 수를 `min(코어 수, 8)`로 제한한다.
  - 그래프는 페이지 단위로 불러온다.
  - 파서는 잘린 입력을 안전하게 처리한다.
  - `fd::`는 `protocol.fd.allow=never`로 차단한다.
- **잔여 위험**: 상한 안에서도 느린 저장소는 있다. 성능 예산 문제로 다룬다.
- **검증**: SEC-T15-01 (20MB를 출력하는 테스트 실행 파일 → 상한에서 잘리고 메모리 증가가 상한 근처), SEC-T15-02 (잠자는 테스트 실행 파일 → 타임아웃 후 종료, 좀비 없음), SEC-T15-03 (잘린 입력 파서 처리)
- **상태**: 설계 완료

### T16. 로그를 통한 정보 유출

- **설명**: 경로, 저장소 이름, 커밋 메시지, 원격 URL이 시스템 로그에 남아 다른 프로세스나 진단 리포트로 새어 나갈 수 있다.
- **대응**:
  - `os.Logger`의 `privacy: .private`를 쓰고, 원격 URL과 stderr는 로깅 전에 마스킹한다.
  - 명령 로그에는 서브커맨드, 소요 시간, 종료 코드, 바이트 수만 남긴다.
  - 기본 로그 수준은 `notice`다.
  - 텔레메트리가 없다. gh 텔레메트리도 `GH_TELEMETRY=0`, `DO_NOT_TRACK=1`로 끈다 (ADR-0004).
- **잔여 위험**: 개발 장비에서 private 로그가 풀릴 수 있다. 마스킹으로 자격 증명은 보호한다.
- **검증**: SEC-T16-01 (테스트에서 `OSLogStore`로 현재 프로세스 로그를 수집해 자격 증명 패턴과 원격 URL 원문이 없음을 확인)
- **상태**: 설계 완료

### T17. 공급망

- **설명**: 의존성이나 CI Action이 오염되면 빌드 산출물이나 저장소 비밀이 위험해진다.
- **대응**:
  - 외부 패키지 0개 (ADR-0006)
  - GitHub Actions는 전체 커밋 SHA로 고정하고 Dependabot으로 갱신한다.
  - 워크플로우 `permissions:`는 최소로 둔다.
  - `pull_request_target`은 보드 동기화(`board-sync.yml`, ADR-0016) 한 곳에서만 쓴다. 지키는 조건은 다음과 같다.
    - 기본 브랜치만 체크아웃하고(`persist-credentials: false`) PR 코드는 체크아웃하거나 실행하지 않는다.
    - 이벤트에서는 이슈·PR 번호만 쓴다.
    - 메인테이너가 아닌 사람의 이벤트는 동시성 그룹 하나를 공유한다.
    - PR은 자기 브랜치 이름의 이슈를, 그 이슈를 가진 사람이 낸 경우에만 움직인다.
  - 보드 토큰 `PROJECT_TOKEN`은 `project` scope 하나만 가진 classic token이다. 보드 #4에만 쓰기 권한이 있는 전용 머신 계정의 토큰을 권장한다.
  - PR 제목·본문 같은 신뢰할 수 없는 값은 `env:`로만 넘긴다.
  - CI의 gitleaks는 버전과 SHA-256을 고정해 받는다.
- **잔여 위험**:
  - Apple 툴체인과 GitHub 러너 이미지는 신뢰한다.
  - 보드 토큰이 새면 그 계정이 쓸 수 있는 모든 Projects 보드가 바뀔 수 있다. 메인테이너 계정 토큰이면 메인테이너가 속한 조직의 보드도 포함된다. 저장소 코드와 이슈는 영향이 없다.
  - `pull_request_target`은 첫 기여자 승인 없이 실행된다. 외부 사용자가 이벤트를 많이 만들면 토큰 계정의 API 한도를 쓸 수 있다. 공유 동시성 그룹으로 상한을 둔다.
- **검증**: SEC-T17-01 (SPM 의존성·`Package.resolved` 없음 — `scripts/lint/check-no-dependencies.sh`와 그 테스트, CI `build-test`), SEC-T17-02 (워크플로우의 모든 `uses:`가 40자리 SHA로 고정), SEC-T17-03 (Dependabot 설정 존재), 보드 상태 규칙은 `scripts/github/board-sync-rules.test.sh`(CI `build-test`)
- **상태**: 적용됨 (저장소 셋업: 워크플로우와 Dependabot, SEC-T17-01은 #33에서 CI에 추가)

### T18. 공개 저장소에 비밀 정보·개인 경로 커밋

- **설명**: 이 프로젝트 자체가 공개 저장소다. 토큰, 개인 홈 경로, 내부 저장소 이름이 커밋·이슈·PR에 들어갈 수 있다.
- **대응**:
  - gitleaks를 세 단계에서 실행한다: pre-commit(스테이징 영역), pre-push(푸시할 범위), CI(`gitleaks` 필수 검사).
  - `.gitleaks.toml`에 개인 홈 경로(`/Users/<이름>/`) 규칙을 둔다.
  - GitHub Secret scanning과 Push protection을 켠다.
  - Claude Code hook이 편집 내용에서 비밀 정보와 개인 경로를 막는다.
  - 공개 글은 게시 전에 승인을 받는다.
  - 테스트 픽스처의 가짜 자격 증명은 `gitleaks:allow` 주석이나 픽스처 경로 allowlist로 명시한다.
- **잔여 위험**: 규칙 밖 형식의 비밀은 놓칠 수 있다. 리뷰 체크리스트로 보완한다.
- **검증**: SEC-T18-01 (gitleaks가 pre-commit, pre-push, CI에서 동작), SEC-T18-02 (개인 경로 규칙이 샘플을 잡아냄)
- **상태**: 적용됨 (저장소 셋업)

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
-c core.alternateRefsCommand=
-c log.showSignature=false
-c gc.auto=0
-c maintenance.auto=false
-c color.ui=never
```

diff 계열 서브커맨드에는 `--no-ext-diff --no-textconv`를 붙인다.
status에는 `--ignore-submodules=dirty`를 붙인다.
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
| `GIT_ALLOW_PROTOCOL` | fetch: `https:ssh:git:file:http` (내장 전송만). 조회: 빈 값(전송 없음, lazy fetch 차단, #212). 부모 값은 무시 |
| `GIT_NO_LAZY_FETCH` | `1` (모든 명령, git 2.44+에서 promisor lazy fetch 금지, #212) |
| `GIT_SSH_COMMAND` | 신뢰 scope `core.sshCommand` 또는 `ssh -o BatchMode=yes` |
| `PATH` | `/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin` |
| `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SSH_AUTH_SOCK` | 부모 값 |

gh 전용 추가 변수는 [카탈로그 §5](../architecture/git-command-catalog.md)에 있다.

### 3.3 RepoConfigInspector 탐지 키

키는 `section.subsection.variable` 형식이다. section과 variable은 소문자로 정규화된 상태에서 비교하고, subsection은 `.`이 들어갈 수 있다. 대상 scope는 `local`과 `worktree`다.

| 정규식 | 범주 | 처리 | 위협 |
|---|---|---|---|
| `^filter\.(.+)\.(clean\|smudge\|process\|required)$` | 실행 | **무력화**: 드라이버별 `-c` 4종 (모든 명령) | T4 |
| `^credential\.helper$`, `^credential\..+\.helper$` | 실행 | **무력화**: 초기화 + 신뢰 항목 재삽입 (fetch) | T6 |
| `^core\.sshcommand$` | 실행 | **무력화**: `GIT_SSH_COMMAND` (항상) | T5 |
| `^core\.gitproxy$` | 실행 | **무력화**: 빈 `GIT_PROXY_COMMAND` (항상) | T5 |
| `^remote\..+\.uploadpack$` | 실행 | **무력화**: `--upload-pack` (fetch, 항상) | T5 |
| `^http\.(.+\.)?sslverify$` | 전송 보안 | **무력화**: 값과 관계없이 같은 키 `=true` (fetch). git은 `0k`, `0x0`, `-0` 등도 false로 읽으므로 추측하지 않는다 (#150 리뷰) | T11 |
| `^http\.(.+\.)?proxy$` | 전송 보안 | **무력화**: 같은 키에 신뢰 scope 값, 없으면 빈 값 (fetch). 로컬 프록시가 신뢰 helper가 내준 자격 증명을 받을 수 있다 (#150 리뷰 실측) | T11 |
| `^core\.fsmonitor$` | 실행 | 보고 (공통 인자로 차단) | T1 |
| `^core\.hookspath$` | 실행 | 보고 (공통 인자로 차단) | T2 |
| `^core\.askpass$` | 실행 | 보고 (공통 인자와 환경으로 차단) | T12 |
| `^diff\.external$`, `^diff\..+\.(textconv\|command)$` | 실행 | 보고 (`--no-ext-diff --no-textconv`) | T3 |
| `^gpg\.(.+\.)?program$`, `^log\.showsignature$` | 실행 | 보고 (공통 인자, 서명 포맷 금지) | T7 |
| `^protocol\.(.+\.)?allow$` | 전송 | 보고 (`GIT_ALLOW_PROTOCOL`이 모든 값보다 우선, `ext`·`fd`는 공통 인자로도 never) | T5 |
| `^remote\..+\.url$` (값이 `<helper>::`로 시작: `^([A-Za-z0-9][A-Za-z0-9+.-]*)?::`, `ext::`·`fd::` 포함. 또는 `<scheme>://`인데 scheme이 `http`·`https`·`ftp`·`ftps`·`git`·`ssh`·`git+ssh`·`ssh+git`·`file`이 아님, 대소문자 무시) | 전송 | 보고 (`GIT_ALLOW_PROTOCOL`로 차단됨, #161, `TransportName`) | T5 |
| `^remote\..+\.vcs$` | 전송 | 보고 (원격 helper 지정, `GIT_ALLOW_PROTOCOL`로 차단됨, #161) | T5 |
| `^remote\..+\.(promisor\|partialclonefilter)$`, `^extensions\.partialclone$` | 전송 | **무력화**: 조회는 전송을 쓰지 않음(빈 `GIT_ALLOW_PROTOCOL`, `GIT_NO_LAZY_FETCH=1`). 누락 객체가 필요한 조회는 실패한다 (#212) | T5 |
| `^remote\.<n>\.fetch$` (대상이 `refs/remotes/<n>/` 밖. 대상 없는 refspec과 `^` negative refspec 제외) | 쓰기 | **무력화**: fetch는 명령줄 refspec + `--refmap=`만 쓴다 (#209) | T13 |
| `^fetch\.prunetags$`, `^remote\..+\.prunetags$`, `^remote\..+\.tagopt$` | 쓰기 | **무력화**: `-c …pruneTags=false`, `--no-tags` (#209) | T13 |
| `^fetch\.bundleuri$` | 쓰기·전송 | **무력화**: `-c fetch.bundleURI=` (임의 URI에서 bundle을 받아 `refs/bundles/*`를 쓰는 것을 막음, #210 보안 검토) | T13 |
| `^remote\..+\.mirror$` | 쓰기 | 보고 (fetch는 명령줄 refspec만 쓰므로 영향 없음, #209) | T13 |
| `^url\..+\.(insteadof\|pushinsteadof)$` | 전송 | 보고 | T5 |
| `^http\.(.+\.)?(sslcainfo\|sslcapath\|sslcert\|sslkey)$` | 전송 보안 | 경고 + **fetch 차단** (조회는 허용) | T11 |
| `http`·`credential`·`filter` 키의 subsection에 `=` | 구성 | **조회 차단**: git이 `-c`를 첫 `=`에서 잘라 다른 키를 주입할 수 있다 (#150 리뷰) | T9 |
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
| `^core\.pager$`, `^pager\..+` | 실행 | 무시 (`--no-pager`) | T10 |

필터 드라이버 이름이 `^[A-Za-z0-9._-]{1,64}$`를 벗어나면 무력화 인자를 안전하게 만들 수 없다. 이때는 조회를 막는다 (fail closed).

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
| E41 | `clone --filter=blob:none`으로 만든 partial 저장소 + 로컬 `remote.origin.uploadpack` canary에서 `diff-tree -p` (Apple Git 2.50.1, #212) | fetch 목록 환경: canary 실행(lazy fetch). `GIT_NO_LAZY_FETCH=1`: 차단. `GIT_ALLOW_PROTOCOL=`(빈 값)·`=none`: `transport 'file' not allowed`로 차단. `-c remote.origin.promisor=false`·`-c remote.origin.uploadpack=git-upload-pack`: 여전히 실행. 앱의 fetch는 partial 저장소에서도 lazy fetch를 하지 않음 |

릴리스 노트로 확인한 도입 버전은 다음과 같다. `--end-of-options` 2.24, `config --show-scope` 2.26, `git maintenance` 2.29, `--diff-merges` 2.31, `stash show --include-untracked` 2.32, porcelain v2 `--show-stash` 2.35, `worktree list -z` 2.36, `--attr-source` 2.41.

### 4.2 확인하지 못한 것 (추정)

| 항목 | 현재 판단 | 확정 방법 |
|---|---|---|
| 위 동작이 최소 버전 git 2.36에서도 같은지 | 같다고 추정 (관련 옵션이 모두 2.36 이전에 도입됨) | CI 호환성 매트릭스 (Phase 4 이슈) |
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
| T1–T18 SEC 테스트 | 전부 통과 (`OvergroveTests/Security`, `OvergroveTests/Integration`) |
| 악성 픽스처 | `scripts/make-fixture-repo.sh --malicious`의 모든 canary가 생성되지 않음 |
| 인자 스냅샷 | 카탈로그와 일치 |
| 금지 API 검사 | 통과 |
| gitleaks | 전체 이력 통과 |
| Actions 고정 | 모든 `uses:`가 SHA로 고정 |
| 잔여 위험 | 이 문서 §2의 잔여 위험을 다시 확인하고 변경 사항을 기록 |

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
