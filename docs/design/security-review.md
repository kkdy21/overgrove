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
| macOS, `/usr/bin/git`(Apple 서명), 사용자가 설치한 `gh` | 저장소 안의 모든 것: 작업 트리 파일, `.gitattributes`, `.gitmodules` |
| git의 `system`, `global`, `unknown`(Apple 내장), `command` scope 설정 | `.git/config`(`local`), `config.worktree`(`worktree`), 그 설정이 include한 파일 |
| 사용자가 `NSOpenPanel`로 고른 경로 | `.git/info/attributes`, `.git/hooks/*`, 서브모듈의 `.git/modules/*/config` |
| 설정에서 사용자가 고른 git 실행 파일 중 [ADR-0019](../adr/0019-user-chosen-git-executable.md)의 경로·소유자·권한·버전 규칙을 통과한 것 (v0.2.0, #106) | 등록된 저장소 안에 있거나, root·현재 사용자가 아닌 소유자 또는 group·other 쓰기 권한이 있는 경로의 실행 파일 |
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
  - numstat 계열(`diff-tree --numstat`, `stash show --numstat`, 파일 이력의 `log [--follow] --numstat`(#70))은 실험에서 textconv를 부르지 않았다. 그래도 같은 인자를 붙인다. log 계열은 patch(`-p`, `--stat` 등)를 요청하지 않고, diff 출력 옵션(`--numstat`, `--raw`, `--name-status` 등)은 두 인자와 함께일 때만 쓴다(SEC-T3-02, 측정 E24a).
  - porcelain `git diff`는 저장소의 diff 설정으로 출력 모양이 바뀐다(#239, catalog §3). `color.diff=always`가 `color.ui=never`를 이기고, `diff.noprefix`·`mnemonicPrefix`·`srcPrefix`·`dstPrefix`가 접두사를 바꾸고, `diff.suppressBlankEmpty`가 문맥 줄을 바꾸고, `diff.submodule=diff`는 서브모듈 쪽 파일 diff까지 붙인다. 화면이 patch를 잘못 읽거나 서브모듈 내용이 섞이지 않게, porcelain diff case에 `--no-color --src-prefix=a/ --dst-prefix=b/ --submodule=short`를 붙이고 공통 인자에 `-c diff.suppressBlankEmpty=false`를 둔다.
- **잔여 위험**: 새 diff 명령을 추가할 때 인자를 빠뜨릴 수 있다. 그래서 카탈로그의 모든 diff case를 SEC-T3-02가 열거해 검사한다.
- **검증**: SEC-T3-01 (textconv, `diff.<d>.command`, `diff.external` 픽스처 → canary 없음), SEC-T3-02 (diff 계열 case 전수 인자 검사), SEC-T3-03 (저장소 diff 설정 8종을 심어도 porcelain diff 5종의 앱 출력이 바이트 단위로 같음. 대조군(고정 인자·공통 인자 없이)은 달라짐. 고정 인자를 비우면 실패함을 확인, #239)
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
  - 서브모듈 쪽 필터는 `--ignore-submodules=dirty`로 재귀를 막아 차단한다. status뿐 아니라 **작업 트리를 보는 diff(`worktreeDiff`)도** 같다. 경로가 서브모듈이면 미스테이지 diff가 서브모듈 안에서 `status`를 돌려 서브모듈 자체의 filter를 실행했다(확인, #239). `--cached`는 서브모듈 안을 보지 않는다. 트리끼리 비교하는 명령(stash·커밋 diff, 파일 이력)은 서브모듈 작업 트리를 보지 않는다.
- **대안 검토**: `--attr-source=<empty tree>`(git 2.41+)는 트리의 `.gitattributes`만 막고 `.git/info/attributes`는 막지 못한다 (확인). 주 대응이 될 수 없다.
- **잔여 위험**:
  - global 설정에 정의된 필터(예: 사용자가 설치한 Git LFS)는 신뢰 범위라 그대로 실행된다. 의도된 동작이다.
  - 로컬에 정의된 LFS 필터를 무력화하면 LFS 파일이 변경으로 보일 수 있다.
- **워크트리 경로는 믿지 않는다(#87, #221 보안 검토)**: `worktree list`의 경로는 저장소가 쓰는 `.git/worktrees/<id>/gitdir`에서 온다. 위조된 항목이 따로 둔 다른 저장소를 가리키면, 그 경로에서 실행한 status가 검사하지 않은 그 저장소의 filter를 실행한다(대조군으로 확인, E43). 연결 워크트리의 `config.worktree`도 메인 워크트리 검사에 나오지 않는다. 그래서 `RepositoryService`는 워크트리마다 그 워크트리가 이 저장소의 것인지 확인한 뒤에만 git을 실행하고(T14, #226), 그 워크트리에서 `configList`를 검사해 그 워크트리의 무력화 인자로 status를 실행한다. `config.worktree`가 조회를 막으면 그 워크트리만 `.inspectionBlocked`가 되고 status는 실행하지 않는다.
- **검사 결과를 캐시해도 낡은 결과를 쓰지 않는다(#88)**: `RepositoryService`는 워크트리마다 설정 검사 결과를 캐시한다(`RepoConfigInspectionCache`). 낡은 검사 결과로 status를 실행하면 그 뒤에 추가된 filter 드라이버가 무력화되지 않는다(대조군으로 확인). 그래서 다음 규칙을 둔다.
  - 지문은 그 폴더에서 git이 읽는 설정 파일 전부를 `stat(2)`으로 찍는다: 공통 `config`, 두 `config.worktree`, `commondir`, `.git`. 장치·inode·크기·mtime·**ctime**을 비교한다. mtime은 되돌릴 수 있지만(`touch -m`, 압축 해제) ctime은 사용자 공간에서 되돌릴 수 없다.
  - 지문은 `config --list` 실행 **전에** 찍는다.
  - 저장소가 제어하는 `include.path`·`includeIf.*.path`가 있으면 캐시하지 않는다. 포함된 파일은 지문에 없고, 작업 트리의 추적 파일일 수도 있기 때문이다(fail closed).
  - ⌘R은 그 저장소의 검사 캐시를 모두 버린다. 검사가 막히면 그 저장소의 결과 캐시도 버린다.
- **검증**: SEC-T4-01 (`.gitattributes` 필터 → canary 없음), SEC-T4-02 (`.git/info/attributes` 필터), SEC-T4-03 (`required=true`여도 status 성공), SEC-T4-04 (허용 밖 드라이버 이름 → 조회 차단), SEC-T4-05 (서브모듈 필터: status와 `worktreeDiff`(미스테이지·스테이지) → canary 없음, 인자만 빼면 실행되는 대조군, #239), SEC-T4-06 (그래프 포맷의 `%(trailers)`가 로컬 `trailer.<key>.cmd`/`.command`를 실행하지 않음, #160), `RepositoryServiceCacheTests.testChangedWorktreeConfigurationIsInspectedAgain`·`testChangedSharedConfigurationIsInspectedAgain`·`testRepositoryLocalIncludeIsNeverServedFromTheCache` (캐시 후 설정이 바뀌면 다시 검사해 새 드라이버가 실행되지 않음. 대조군은 낡은 검사 결과로 실행됨, #88), `RepoConfigInspectorTests.testFingerprintSeesARewriteThatRestoresSizeAndModificationTime` (크기·mtime을 되돌려도 지문이 바뀜), `RepositoryServiceTests.testForgedWorktreeEntryPointingAtAnotherRepositoryIsNotQueried`·`testLinkedWorktreeOwnConfigurationIsInspected` (대조군에서는 filter 실행, 앱 경로에서는 실행 안 됨), SEC-T4-07 (연결 워크트리의 `config.worktree`가 조회를 막으면 그 워크트리만 `.inspectionBlocked`이고 status가 실행되지 않음. 워크트리 전용 드라이버는 `testLinkedWorktreeOwnConfigurationIsInspected`, #226), SEC-T4-08 (Diff 뷰어(S-10) 경로 — 소속 재확인, 그 워크트리 설정 검사, 그 safety로 `worktreeDiff`·`untrackedPreview` — 가 `--malicious` 픽스처의 staged·unstaged·untracked 파일에서 canary를 실행하지 않음, #232)
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
  - **조회는 전송을 쓰지 않는다(#212)**: `GitClient.run`의 환경은 `GIT_ALLOW_PROTOCOL=`(빈 값)이다. 이것이 `GitEnvironment.environment`의 기본값이고, 전송은 `GitClient.fetch`만 `allowsTransport: true`로 연다(#215). 빈 목록은 모든 전송을 원격 helper·uploadpack·credential helper 실행 전에 거부한다(`transport 'file' not allowed`, 확인 E42). git의 protocol policy(2.12+)라서 최소 지원 2.36부터 모든 버전에 적용된다(소스 기준. #99·#317에서 2.36.6·2.39.5·2.40.4·2.44.0·2.45.0도 실행해 확인). 모든 명령에 `GIT_NO_LAZY_FETCH=1`을 두 번째 층으로 둔다. 이 변수가 모든 lazy fetch를 막게 된 것은 2024년 5월 git 보안 릴리스부터다: 2.45.1, 2.44.1과 2.39.4·2.40.2·2.41.1·2.42.2·2.43.4 백포트. 백포트가 없는 2.44.0 이하는 변수를 모르고, 2.45.0은 변수가 있지만 fetch 중의 lazy fetch는 막지 못한다(각 버전 tarball 소스와 실측으로 확인, #317). `-c remote.<n>.promisor=false`와 `-c remote.<n>.uploadpack=…`로는 막히지 않는다(로컬 값이 이김, 확인). fetch만 `https:ssh:git:file:http` 목록을 쓴다.
  - **fetch 중의 lazy fetch(#213 보안 검토)**: fetch도 받은 객체가 로컬에 없는 blob을 delta base로 쓰면 lazy fetch를 하며, 이때는 고정한 `--upload-pack`이 적용되지 않아 로컬 uploadpack이 실행된다(filter 설정 없이 promisor만 있는 저장소, 실측). `GIT_NO_LAZY_FETCH`를 지원하는 git은 이것으로 막혀 fetch가 안전하게 실패한다. **`lazyFetchControlVersion`(2.45.1) 미만에서는 partial clone의 fetch를 거부한다**(`configInspectionFailed`). partial clone 판정은 두 신호 중 하나다. ① git이 원격을 promisor로 다루게 하는 설정 전부: 어느 scope든 `remote.<n>.promisor`, `remote.<n>.partialclonefilter`(값 무관), `extensions.partialclone`(빈 값 포함)(`RepoSafetyContext.isPartialClone`). ② 독립 신호로, 공통 git 디렉터리의 `objects/pack`에 `.promisor` 파일이 있는 경우(`GitClient.hasPromisorPack`). ②는 이름만 읽고 링크는 따라가지 않는다. 링크, 읽을 수 없는 폴더, 폴더가 아닌 것, 스캔 상한 초과처럼 판단할 수 없으면 partial clone으로 본다. 폴더가 없을 때만 pack이 없다고 본다. 설정 목록이 git 내부를 따라가는 방식이라 빠질 수 있어서 둔 심층 방어다(#317). 기준은 원래 2.44.0이었다. 하지만 2.44.0과 2.45.0은 보안 릴리스보다 먼저 나와 fetch 중의 lazy fetch를 막지 못한다. 그래서 기준을 2.45.1로 고쳤다(#317, SEC-T5-18). 같은 이슈에서 git이 promisor로 다루는 설정 키 하나가 판정에서 빠져 있던 것도 고쳤다(①). 버전 비교라서 고쳐진 2.44.1과 백포트된 2.39.4–2.43.x도 거부하는데, 안전한 쪽으로 남긴 것이다.
  - 대가: 사용자가 직접 만든 partial clone에서 누락 객체가 필요한 조회(과거 커밋 diff, `fileHistory`)는 실패한다. partial 서브모듈이 있는 상위 저장소의 status도 실패할 수 있다(실측). 안전한 방향의 실패이고 메시지로 알린다.
  - **공통 인자 `-c protocol.ext.allow=never -c protocol.fd.allow=never`**: `ext::`와 `insteadOf` 바꿔치기, `fd::` 차단 (확인). `GIT_ALLOW_PROTOCOL`과 겹치지만 심층 방어로 유지한다.
  - **fetch 전 원격 형태 검사(#350)**: 내장 전송(https, ssh, git, file) 형태가 아닌 원격은 fetch 전에 거부한다. `<이름>::<주소>` URL, git이 직접 처리하지 않거나 대소문자가 다른 `<scheme>://`, `remote.<n>.vcs`, `insteadOf`로 바꾼 결과가 내장 형태가 아닌 URL이 해당한다. 검사는 `RepoConfigInspector`가 하고 `GitClient.fetch`가 통과한 원격만 실행한다(`fetchableRemotes`, 기본값은 비어 있음). 상세 규칙은 [git-command-catalog.md §4](../architecture/git-command-catalog.md#4-fetchcommand).
  - **공통 인자 `-c alias.remote-<이름>=`와 `-c help.autocorrect=0`(#350)**: 관련 저장소 설정을 무력화하는 심층 방어. 원격 형태 검사를 거치지 않고 fetch가 시작되더라도 효과가 있다(확인: git 2.36.6, Apple Git 2.54.0, Homebrew 2.54.0).
  - **공통 인자 `-c core.alternateRefsCommand=`(빈 값)**: alternates 경로 무력화. 빈 값이어도 fetch는 성공한다 (확인).
  - fetch는 `--no-recurse-submodules`로 서브모듈 원격에 연결하지 않는다.
- **잔여 위험**:
  - 로컬 경로 원격(`file://` 또는 경로)을 fetch하면, **상대 저장소**에서 `git-upload-pack`이 실행되면서 그 저장소의 설정을 읽는다. 상대 저장소의 설정은 검사하지 않는다. v0.2.0의 "신뢰하지 않음 모드"(#107)에서는 `GIT_ALLOW_PROTOCOL` 목록에서 `file`을 빼는 방식으로 막을 수 있다 (`transport 'file' not allowed`, 확인).
  - 내장 전송만 허용하는 데 따른 사용 제약(`ftp://`·`ftps://`, 커스텀 원격 helper는 fetch 불가, 허용하더라도 앱 설정으로만)은 사용자 안내 [guides/self-hosted-git.md §Limits](../guides/self-hosted-git.md#limits)로 옮겼다(#161, #152).
  - 사용자가 global에 정의한 `core.gitProxy`는 v0.1에서 무시된다 (빈 `GIT_PROXY_COMMAND`). `git://` 프로토콜은 드물어서 감수한다.
  - **터미널로 보내는 안내.** fetch 실패 안내(`FetchFailureGuidance`, #78)가 사용자를 터미널로 보내면, 터미널의 git은 이 문서의 대응을 하나도 적용받지 않는다. 악성 저장소가 일부러 fetch를 실패시켜(예: 처음 보는 호스트로 `hostKeyNotTrusted`) 사용자가 페이로드를 직접 실행하게 만들 수 있다(#200 보안 검토).
    - 그래서 `git` 명령은 `RepoSecurityReport`에 항목이 없을 때만 복사용으로 제시하고, 그때도 "신뢰하는 저장소에서만"이라고 쓴다.
    - 항목이 있으면 저장소를 읽지 않는 명령(`ssh-add -l`, `ssh-keyscan … | ssh-keygen -lf -`, `ssh-keygen -F`)만 제시한다.
    - 남는 위험: `.git/hooks`는 설정 보고에 나오지 않으므로, 보고가 깨끗해도 터미널 git이 hook을 실행할 수 있다. 안내 문구가 이를 경고한다.
    - 두 번째 경로는 느린 status 안내(`SlowStatusHint`, #168)다. 저장소가 status를 일부러 느리게 만들어 안내를 띄울 수 있고, 권하는 `git status`는 index를 다시 써서 `post-index-change` hook을 실행할 수 있다. 그래서 설정 보고에 항목이 없고 **S-05의 hook 검사(`hookExecutables`)가 비어 있을 때만** 복사용 명령을 제시한다. 검사 결과가 없으면(상태바) 명령을 제시하지 않는다. 문구는 FetchFailureGuidance처럼 hook과 설정을 경고한다(SEC-T5-17). pager·editor·`!` alias는 #278부터 보고에 나온다.
- **검증**: SEC-T5-01 (sshCommand), SEC-T5-02 (uploadpack, 로컬 원격), SEC-T5-03 (`ext::`), SEC-T5-04 (`insteadOf` → `ext::`), SEC-T5-05 (gitProxy), SEC-T5-06 (`fd::` 차단, 정지 없음), SEC-T5-07 (alternates 저장소 fetch에서 `alternateRefsCommand` canary 미생성), SEC-T5-08 (`<helper>::` URL), SEC-T5-09 (로컬 `protocol.<helper>.allow=always`), SEC-T5-10 (`insteadOf` → `<helper>::`), SEC-T5-11 (`remote.<n>.vcs`), SEC-T5-12 (명령줄 `-c protocol.allow=never`로는 부족함), SEC-T5-13 (로컬 경로 원격은 계속 허용), SEC-T5-14 (https는 전송 정책으로 거부되지 않음), SEC-T5-15 (git이 직접 처리하지 않는 `<scheme>://` URL), SEC-T5-17 (느린 status 안내는 설정 보고에 항목이 없고 hook 실행 파일이 없을 때만 `git status`를 제시하고, 항목·hook이 있거나 검사 결과가 없으면 명령이 없음, #168), SEC-T5-16 (이미 partial인 저장소 + 로컬 uploadpack canary: 앱 조회(`commitPatch`, `commitFiles`, `fileHistory`) 뒤 canary 없음, 대조군(#212 이전 환경)은 실행), SEC-T5-20 (내장 전송 형태가 아닌 원격: `<이름>::` URL, `remote.<n>.vcs`, `insteadOf` 바꿔치기를 앱 fetch가 git 실행 전에 거부하고 canary 없음, 대조군은 실행. `RepositoryService`는 원격별 실패로 보고, #350), SEC-T5-21 (원격 형태 검사를 우회해도 공통 인자만으로 canary 없음, 저장소가 켤 수 있는 두 가지 대체 경로 모두, 대조군은 실행, #350. 두 테스트 모두 git 2.36.6·Apple Git·Homebrew git에서 확인), SEC-T5-18 (partial clone fetch: `lazyFetchControlVersion` 경계 2.45.0 거부·2.45.1 허용, 두 가지 pack 처리 경로와 promisor 설정 두 종류에서 앱 fetch 뒤 canary 없음, 대조군은 실행하되 저장소는 그대로. 설정이 없어도 `.promisor` pack이 있으면 거부, 판단할 수 없는 pack 폴더는 fail closed. `OVERGROVE_TEST_GIT`로 git 2.36·2.44.0·2.45.0을 주면 거부 경로를 실제 git으로 확인한다)
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
- **검증**: SEC-T9-01 (모든 case의 최종 인자 배열 스냅샷. 기준 브랜치 비교의 기준 ref는 `--end-of-options` 뒤, 파일은 `--` 뒤, #157), SEC-T9-02 (ref 검증: `-x`, `refs/heads/a..b`, 제어 문자 거부), SEC-T9-03 (파일명 `-x`, `--output=x`, `:(exclude)x`, `*`로 diff·이력 → 해당 파일만 대상, 부수 파일 생성 없음), SEC-T9-04 (OID 검증), SEC-T9-05 (원격 URL → gh `--repo` 값: github.com 세 형식의 `OWNER/NAME`만. `-` 시작·비ASCII·userinfo·포트·다른 호스트·경로 추가 거부, #81)
- **상태**: 설계 완료

### T10. 부모 환경 변수 상속

- **설명**: 앱을 터미널에서 실행하면 `GIT_DIR`, `GIT_CONFIG_PARAMETERS`, `GIT_SSH_COMMAND`, `GIT_EXTERNAL_DIFF`, `GIT_EXEC_PATH`, `DYLD_*` 같은 변수가 상속되어 git 동작이 바뀐다.
- **시나리오**: 다른 도구가 설정한 `GIT_DIR` 때문에 엉뚱한 저장소를 조회한다. `GIT_EXTERNAL_DIFF`가 의도치 않은 프로그램을 실행한다.
- **대응**: 환경 변수를 allowlist로 새로 만든다 (§3.2). 부모 환경은 `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SSH_AUTH_SOCK`만 전달한다. PATH는 고정값이다. 페이저는 `--no-pager`와 `GIT_PAGER=cat`으로 이중 차단한다. gh는 별도 allowlist(`HOME`, `USER`, `TMPDIR`와 고정값, [카탈로그 §5](../architecture/git-command-catalog.md))를 쓴다. `GH_TOKEN`, `GITHUB_TOKEN`, `GH_HOST`, `GH_REPO`, `GH_CONFIG_DIR`, 브라우저·편집기 변수는 gh에 전달하지 않는다.
  - **사용자가 고른 git 실행 파일(v0.2.0, #106)**: [ADR-0019](../adr/0019-user-chosen-git-executable.md)를 따른다. 절대 경로이고, 링크를 푼 실제 파일이 일반 실행 파일이어야 한다. 등록된 저장소 안의 경로는 거부한다. 실제 파일과 상위 디렉터리(입력 경로 쪽 포함)는 root 또는 현재 사용자 소유이고 group·other 쓰기 권한이 없어야 한다. 버전은 2.36 이상이어야 한다. 고를 때와 git을 찾을 때마다 다시 검사하고, 실패하면 기본 git으로 바꾸지 않고 조회를 멈춘다(fail closed). 코드 서명은 요구하지 않고 표시만 한다.
- **잔여 위험**: 사용자의 셸 설정에 의존하던 git 동작(예: 셸에서만 설정한 `GIT_SSH_COMMAND`)은 앱에서 동작하지 않는다. 의도된 동작이고 문서화한다. `HOME`은 부모 값을 그대로 쓰므로, 앱 실행 환경을 바꿀 수 있는 같은 사용자는 git·gh가 읽는 전역 설정(`~/.gitconfig`, `~/.config/gh`)과 gh 계정 선택을 바꿀 수 있다. 이 권한은 원래 신뢰 경계 밖이다. gh 실행 파일은 경로를 탐색한 뒤 `posix_spawn`이 다시 해석하므로(TOCTOU), 그 사이에 `/opt/homebrew/bin`에 쓸 수 있는 사용자는 실행 파일을 바꿀 수 있다. 위협 모델은 사용자가 설치한 gh를 신뢰하므로(§1) 받아들인다. 사용자가 고른 git의 검사와 실행 사이 바꿔치기(TOCTOU)는 소유자·권한 규칙상 root나 그 사용자만 할 수 있어 신뢰 경계 밖이다(ADR-0019).
- **검증**: SEC-T10-01 (테스트 프로세스 환경에 위험 변수를 넣어도 자식 프로세스 환경에 없음), SEC-T10-02 (PATH 고정), SEC-T10-03 (gh 자식 환경이 카탈로그 §5 allowlist와 정확히 같음. 토큰·호스트·설정 디렉터리 변수 없음, 텔레메트리 끔)
- **상태**: 설계 완료

### T11. 자격 증명 노출

- **설명**: 원격 URL에 `https://user:token@host/...`처럼 자격 증명이 들어 있을 수 있다. 이것이 화면, 로그, 에러 메시지(stderr)로 새어 나갈 수 있다. 또 로컬 설정의 `http.sslVerify=false`는 TLS 검증을 꺼서 중간자에게 자격 증명을 넘길 수 있다.
- **대응**:
  - **`CredentialMasker`**: 아래 패턴을 `***`로 바꾼다. 화면 표시, 로그, 에러 요약 전에 반드시 거친다.
    - URL userinfo (`scheme://user:pass@` → `scheme://***@`, `scheme://token@` → `scheme://***@`)
    - scheme 없는 userinfo (`user:token@host:repo` → `user:***@host:repo`, #244). 첫 `:` 뒤에 `@`가 있으면 그 `:`부터 마지막 `@`까지의 비밀번호만 가린다. `:` 앞은 남긴다. git은 `a:b@c:d`를 호스트 `a`로 가는 scp 형식 SSH로 읽기 때문에, 앞까지 지우면 원격이 `c`를 가리키는 것처럼 보인다(#244 보안 검토, #86). `:` 앞에 미끼 `@`를 두어도 가려진다. scp 형식 `git@host:repo`, 이메일, `bob@host's password:`는 그대로 보인다. 공백 없는 `단어:단어@단어` 꼴(예: `mailto:a@b`, `git@host:repo@v1`)도 가려지는 오탐이 있지만, 글자가 조금 덜 보일 뿐이다. `:` 없는 `token@host`는 사용자 이름과 구별할 수 없어 일반 텍스트에서는 가리지 않는다
    - config 키 이름(S-05, Open in Terminal): `credential`·`url`·`http` subsection은 URL이나 URL 패턴이다. scheme으로 시작하지 않으면 첫 `/` 앞의 마지막 `@`까지를 userinfo로 보고 가린다(`credential.token@host.helper` → `credential.***@host.helper`, `CredentialMasker.maskConfigKey`, #244). 사용자 이름도 URL과 같이 가린다(`url.***@github.com:.insteadof`). 키는 보여 주기만 하고 접속하지 않으므로 호스트 문제가 없다. 다른 섹션의 키는 일반 마스킹만 거친다
    - 쿼리 파라미터 `access_token=`, `token=`
    - GitHub 토큰 접두사 `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`
    - `Authorization:` 헤더 줄
  - **원격 URL 표시**: 기본은 마스킹이다. 설정의 "원격 URL 표시"를 켜도 자격 증명 부분은 계속 마스킹한다. 원격 URL에 자격 증명이 들어 있으면 S-05에 경고하고, credential helper 사용을 권장한다.
  - **TLS 설정**: `local`·`worktree` scope에서 `false`로 설정된 `http.sslVerify`·`http.<url>.sslVerify`를 fetch에서 같은 키의 `true`로 덮는다 (확인: `config --get-urlmatch`). 로컬 `http.*proxy`는 신뢰 scope 값(없으면 빈 값)으로 덮고, 로컬 `http.*sslCAInfo`·`sslCAPath`·`sslCert`·`sslKey`가 있으면 fetch를 막는다(§3.3, #150).
  - 앱은 토큰을 받거나 저장하지 않는다. `gh auth status`는 `--show-token` 없이 호출한다.
  - **보안 보고서 복사(S-05 `Copy Report`, #110)**: 이슈나 대화에 붙여 넣는 글이므로 키 이름과 각 항목의 판정만 담는다. 그 밖에는 고정된 사실(main/linked 워크트리, 검사 시각, git·앱 버전)만 쓴다. config 값, 원격 URL과 호스트, 파일 경로, 브랜치 이름, 오류 문구(경로나 stderr를 인용할 수 있음)는 넣지 않는다. URL이나 경로가 될 수 있는 subsection은 마스킹하지 않고 자리표시로 바꾼다(`credential.<url>.helper`, `http.<url>.sslverify`, `includeif.<condition>.path`). 그 밖의 subsection도 글자로 시작하고 글자·숫자·`_`·`-`만 쓴 이름이 아니면 `<name>`이 된다. `.`이 든 이름은 호스트나 IP일 수 있어서 바꾼다. 자격 증명이 든 원격은 이름만 적는다(`origin (credentials in URL)`, 이름이 평범하지 않으면 `<remote>`). 목록은 행마다 50개까지 적는다. 마지막으로 줄마다 `CredentialMasker`, 홈 → `~`, 제어·bidi 문자 이스케이프를 거친다.
- **잔여 위험**: 새로운 토큰 형식은 마스킹 패턴에 없을 수 있다. URL userinfo는 형식과 관계없이 전부 마스킹하므로 위험이 줄어든다. scheme 없이 `:`도 없는 `token@host`가 config 키가 아닌 텍스트(stderr 등)에 나오면 가리지 않는다. scheme 없는 비밀번호에 `/`가 있으면(`u:pa/ss@h`) `/`가 구간을 끊어 일부가 보인다. git은 이것을 호스트 `u`의 경로로 읽으므로 자격 증명으로 쓰이지 않고, 주요 토큰 형식에는 `/`가 없다(#244).
- **검증**: SEC-T11-01 (`CredentialMasker` 단위 테스트), SEC-T11-02 (fetch 실패 stderr가 마스킹된 뒤에만 UI 모델과 로그에 들어감), SEC-T11-03 (로컬 `sslVerify=false` → 최종 인자로 `true` 복원), SEC-T11-04 (S-05, 상태바의 원격 표시가 마스킹됨), SEC-T11-05 (`GHCommand`의 어떤 인자에도 token이 없고, gh stderr는 마스킹된 뒤에만 `GHError`에 들어감), SEC-T11-06 (S-05 보안 보고서 복사: 적대적 설정에서도 config 값·원격 URL·호스트·경로·홈·토큰·브랜치 이름이 없고 키 이름과 판정만 남음, #110)
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
  - **index 쓰기 방지**: `--no-optional-locks`와 `GIT_OPTIONAL_LOCKS=0`으로 조회 중 `index.lock`을 잡지 않는다. `git diff`는 이 설정을 무시하고 stat만 바뀐 경로의 index를 새로 고쳐 쓰므로, 공통 인자 `-c diff.autoRefreshIndex=false`로 막는다 (확인, #208). 이 인자는 diff 계열이 아닌 명령에는 영향이 없어 공통 인자에 둔다.
  - **허용된 쓰기**: fetch가 만드는 쓰기(`refs/remotes/<원격>/*`, `FETCH_HEAD`, 객체)와 `--prune`의 원격 추적 ref 삭제뿐이다.
  - **fetch 범위 고정(#209)**: 저장소 설정이 이 범위를 넓히지 못하게 fetch 인자에 고정한다. refspec `+refs/heads/*:refs/remotes/<원격>/*`와 `--refmap=`, `--no-tags`, `-c fetch.pruneTags=false -c remote.<원격>.pruneTags=false -c fetch.bundleURI=`를 쓴다([카탈로그 §4](../architecture/git-command-catalog.md)). 고정하기 전에는 로컬 `remote.<n>.fetch=+refs/heads/*:refs/heads/*`(detached HEAD)가 로컬 브랜치를 지우고 `main`을 되돌렸다. 로컬 `fetch.pruneTags`는 로컬 태그를 지웠다(#206 보안 검토, E40).
- **잔여 위험**: 낮음. #94의 테스트와 리뷰에서 찾은 두 결함, `git diff`의 index 쓰기(#208)와 저장소 설정에 의한 fetch 범위 확대(#209)는 고쳤다.
  - `--no-tags` 때문에 원격에만 있는 새 태그는 v0.1에서 가져오지 않는다(의도된 동작, #209).
- **검증**: SEC-T13-01 (모든 case의 서브커맨드가 허용 집합 안에 있음), SEC-T13-02 (status 조회 전후 `.git/index` 내용·mtime 불변, 연결 워크트리 포함. stat만 바뀐 파일의 worktree diff와 기준 브랜치 비교(`git diff --merge-base`, 작업 트리 포함, #157)도 불변이고, `diff.autoRefreshIndex=false`를 빼면 다시 쓰는 대조군 포함. 다른 조회는 `.git` 전체 불변까지 확인), SEC-T13-03 (금지 API 정적 검사. 저장소 전체 통과와 함께, 심은 위반을 실제로 거부하는지 테스트로 확인), SEC-T13-04 (로컬 `remote.<n>.fetch`·`fetch.pruneTags`·`remote.<n>.pruneTags`·`tagOpt`·`fetch.bundleURI`를 심은 저장소에서 앱 fetch 뒤 `refs/remotes/` 밖의 모든 ref와 HEAD 불변, 대조군(고정 전 인자)에서는 브랜치·태그 삭제, `main` 이동, `refs/bundles/*` 생성), SEC-T13-05 (이슈의 `Open in Browser`는 정확히 `https://github.com/OWNER/NAME/issues/<번호>`일 때만 `NSWorkspace`에 넘김. 다른 번호·`pull`·경로 추가·쿼리·조각·사용자 정보·포트 거부, #81)
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
  - **`worktree list`가 나열한 경로도 등록과 같은 기준으로 검증한다(#226)**. 목록은 저장소가 쓰는 `.git/worktrees/<id>/gitdir`에서 오므로, 공통 git 디렉터리가 같다는 것(#221)만으로는 부족하다. 다음 세 위조가 그 검사를 통과했다.
    - 메인 워크트리의 하위 폴더를 가리키는 항목: 같은 작업 트리를 두 번째 행으로 조회한다.
    - `.git`이 정상 연결 워크트리의 `worktrees/<id>`를 빌려 쓰는 폴더: 그 워크트리의 index·HEAD로 엉뚱한 폴더를 그 브랜치 이름으로 보여 준다.
    - 연결 워크트리 `config.worktree`의 `core.worktree`: 등록하지 않은 폴더(예: 홈)를 status가 훑는다.

    그래서 나열된 경로를 `realpath(3)`로 한 번 정규화해 세 명령(probe, config, status)에 같은 폴더를 쓰고, git을 실행하기 전에 파일 시스템으로 확인한다. 메인 워크트리는 `.git`이 공통 디렉터리로 이어져야 하고, 연결 워크트리는 `checkLinkedWorktree`가 `.linked`여야 한다(back-pointer 일치). 그다음 probe가 그 폴더를 워크트리 루트로, 이 저장소의 공통 디렉터리를 보고해야 한다. 하나라도 어긋나면 `.notQueried(.foreignRepository)`다.
  - **행 메뉴(#73)**: Reveal in Finder는 `PathValidator.containment`로 해석한 실제 경로가 워크트리 안일 때만 Finder에 넘긴다. 링크나 `..`로 밖을 가리키면 `This path points outside the repository.`를 보여 주고 열지 않는다. 파일을 기본 앱으로 여는 항목은 없다. Open in Terminal은 존재하는 워크트리 폴더 URL만 Terminal.app에 넘긴다. Open in Browser는 `https`와 호스트가 있는 URL만 연다. 클립보드에는 화면에 보이는 값을 넣는다. 제어·서식(bidi)·줄 구분 문자는 `\u{…}`로 이스케이프해, 파일 이름이 터미널에 붙여 넣을 때 줄바꿈이나 방향 전환 문자를 숨겨 넣지 못하게 한다. 커밋 메시지만 줄바꿈과 탭을 유지한다.
- **잔여 위험**: git 자체가 따라가는 경로(예: alternates 객체 저장소)는 통제하지 않는다. 읽기 전용이라 영향이 제한적이다. Open in Terminal(#73)로 연 셸은 앱 밖이라 보안 인자가 없다. 사용자의 프롬프트 플러그인이 그 폴더에서 `git status`를 실행하면 저장소의 `core.fsmonitor`, filter, hook이 실행될 수 있다. 그래서 `TerminalGuard`가 확인 창을 띄운다. 조건은 다음과 같다.
  - 그 워크트리의 로드 시점 검사(`WorktreeListing.Entry.inspection`)가 없을 때: 검사 전, 차단, 다른 저장소, 실패를 모두 포함한다.
  - 보고서가 차단되었을 때.
  - finding이 하나라도 있을 때(#278 전에는 T1–T7만 봤다). `core.fsmonitor`·`core.hooksPath`처럼 앱에서는 보고만 하는 키도 포함한다. 셸의 git은 이 키를 따르기 때문이다.
  - 실행 가능한 `hooks/*`가 있을 때.

  확인 창은 셸 프롬프트 도구가 이 폴더에서 저장소 설정으로 git을 실행할 수 있다고 알리고, 키 이름(마스킹·이스케이프, 최대 8개)을 보여 준다. 버튼은 `Open Anyway`와 `Cancel`이며 `Cancel`이 기본이다. 검사 결과가 깨끗하면 바로 연다. 사용자가 `Open Anyway`를 고르면 그 셸에서 일어나는 일은 통제하지 않는다.

  **사용자가 칠 git까지 (#278)**: #97 재검토에서 앞의 조건에 빠진 곳을 찾았다. 앱이 실행하지 않는 키(`core.pager`·`pager.<cmd>`, `core.editor`·`sequence.editor`, `!`로 시작하는 `alias.*`)는 보고되지 않았고, threat가 없는 finding(`submodule.<n>.update=!cmd`, `uploadpack.packObjectsHook`, `include.path`)은 확인 사유가 아니었다. 그래서 다음 두 가지를 바꿨다.
  - 검사기가 앞의 키들을 T14 `reported`로 보고한다. 앱의 무력화 인자는 바뀌지 않는다.
  - `TerminalGuard`는 위협·처리 방식과 관계없이 **모든 finding**을 확인 사유로 본다. 앱이 자기 명령에서 덮어쓰거나 무시하는 설정도 셸의 git은 그대로 따르기 때문이다.

  남는 위험: 검사기가 모르는 실행 경로(예: 새 git 버전의 새 키)는 확인 사유가 되지 않는다.
- **검증**: SEC-T14-01 (심볼릭 링크 등록 경로 경고), SEC-T14-02 (저장소 밖을 가리키는 untracked 심볼릭 링크는 링크 문자열만 미리보기하고 대상 내용은 보이지 않음, 상위 디렉터리가 밖으로 나가는 경로는 거부), SEC-T14-03 (로컬 `core.worktree` 보고), SEC-T14-04 (등록 probe 교차 확인: 고른 폴더가 probe의 워크트리 안에 있고, 그 워크트리의 `.git`이 공통 디렉터리로 이어지거나 back-pointer가 맞는 연결 워크트리여야 한다. `core.worktree`나 위조한 `commondir`로 다른 곳을 가리키면 등록 거부, #84. bare 저장소(#222): 고른 폴더가 공통 git 디렉터리 자체이거나, 공통 디렉터리를 바로 아래에 두고 `.git`이 디스크에서 그곳으로 이어지는 폴더여야 하고, 이 위치의 git 디렉터리도 공통 디렉터리여야 한다. bare 안의 하위 폴더, `worktrees/<id>`, 다른 저장소를 `commondir`로 가리키는 폴더, 다른 워크트리의 `.git` 파일을 복사한 폴더, 다른 곳의 bare 저장소를 가리키는 `.git` 파일만 둔 폴더는 거부), SEC-T14-05 (나열된 워크트리 검증: 메인 워크트리 하위 폴더 항목, 연결 워크트리 항목을 빌린 폴더, `config.worktree`의 `core.worktree`는 조회하지 않음. 각 대조군은 #221의 공통 디렉터리 검사를 통과함을 보인다, #226), SEC-T14-06 (Diff 뷰어가 untracked FIFO와 워크트리 밖 폴더를 가리키는 심볼릭 링크 아래 파일을 미리보기하지 않음, #232), SEC-T14-07 (행 메뉴: 밖을 가리키는 링크·링크 폴더·`..`·없는 파일은 Reveal in Finder 거부, `https` 외 URL은 열지 않음, 클립보드 값의 제어·bidi 문자 이스케이프, #73), SEC-T14-08 (Open in Terminal: 깨끗한 검사는 바로 열고, 실행 finding·차단·hook·검사 없음은 확인 후에만 열며, 나열하는 키는 마스킹·이스케이프·상한 적용, #73), SEC-T14-09 (FSEvents 이벤트 경로는 신뢰하지 않는 문자열이다. 검증된 워크트리 폴더(`realpath`)와 공통 git 디렉터리에 컴포넌트 단위로만 비교하고 디스크를 읽지 않는다. 접두사 속임(`/dev/api-other`), 상대 경로, `.`·`..`, 연결 워크트리의 `.git` 파일, 감시 밖 경로는 아무것도 바꾸지 않음, #119), SEC-T14-10 (pager·editor·`!` alias는 T14 `reported`로 보고하고 앱의 인자는 바꾸지 않음. 불리언 `pager.<cmd>`와 신뢰 scope는 보고하지 않음. Open in Terminal은 위협·처리와 관계없이 모든 finding을 확인 사유로 씀, #278)
- **상태**: 설계 완료

### T15. 자원 고갈

- **설명**: 병적인 저장소(거대한 출력, 수백만 개 파일, 끝나지 않는 원격)가 메모리를 고갈시키거나 앱을 멈추게 할 수 있다. `fd::` 원격은 fetch를 정지시켰다 (확인).
- **대응**:
  - 타임아웃: 기본 15초, fetch 120초. SIGTERM 뒤 2초가 지나면 SIGKILL.
  - stdout 상한 10MB(fetch 1MB), stderr 상한 64KB(fetch 256KB). 넘으면 읽기를 멈추고 `truncated` 결과를 돌려준다.
  - 동시 git 프로세스 수를 `min(코어 수, 8)`로 제한한다.
  - **설정 검사도 선형 시간이다(#262)**. `config --list` 출력은 stdout 상한(10MB)까지 저장소가 정한다. 원격, TLS·프록시 키, filter 드라이버의 중복 제거와 신뢰 프록시 값 찾기는 집합과 한 번의 훑기로 한다. 이전에는 앞의 항목을 매번 다시 훑어 O(n²)였다. 검사는 저장소를 열 때와 워크트리마다 실행된다. 남기는 양에도 상한을 둔다.

    | 대상 | 상한 | 넘으면 |
    |---|---|---|
    | filter 드라이버 | 256 | 조회 중단(fail closed). 드라이버마다 모든 git 명령에 인자 8개가 붙고, 모두 무력화하지 못하면 실행하지 않는다 |
    | fetch 전용 덮어쓰기(`http.<url>.sslVerify`·`.proxy`) | 256 | fetch만 막는다. 조회는 계속한다 |
    | 원격 목록 | 1,000 (설정 순서) | 나머지는 개수만 센다(`omittedRemotes`). fetch는 더 적게 쓴다(#259). 무력화와 무관하므로 fail closed가 아니다 |
    | 보고서 항목 | 1,000 | 나머지는 개수만 센다(`omittedFindings`). 무력화는 모든 항목에 그대로 적용한다 |

    S-05는 보고서가 줄었으면 "Report shortened"로 알린다.
  - 한 번의 조회에서 status를 실행하는 워크트리는 최대 64개다(`RepositoryService.defaultMaximumQueriedWorktrees`, #226). 워크트리 목록은 저장소가 쓰는 파일에서 오고 10MB까지 읽으므로, 위조 레코드 수천 개가 각각 프로세스 3개(probe, config, status, 각 최대 15초)와 `WorkingState`를 만들 수 있었다. 64는 PB-1 기준(워크트리 10개)의 6배 남짓이다. 나머지는 목록에만 두고 `.notQueried(.limit)`로 표시하며, 화면은 `RepositoryOverview.isQueryLimited`로 알린다. 같은 경로는 한 번만 나열하고, 다른 경로가 같은 폴더로 이어지면(심볼릭 링크) 한 번만 조회한다(`.notQueried(.duplicate)`).
  - Fetch 한 번이 가져오는 원격은 최대 16개다(`RepositoryService.defaultMaximumFetchedRemotes`, #259). 원격 목록은 저장소 설정이 정하고, 원격마다 최대 120초씩 순서대로 돌기 때문에, 원격 수천 개를 넣으면 Fetch 한 번이 사실상 끝나지 않고 앱 전체 fetch 슬롯 2개 중 하나를 붙잡았다. 보통은 1~3개(origin, upstream, fork 몇 개)이고 16은 fork가 많은 리뷰 환경도 담는다. 최악의 경우는 약 32분이며, Stop과 창 닫기는 언제든 멈춘다. 설정 순서로 앞의 16개만 가져오고, 건너뛴 수는 상태바(`· 16 of 40 remotes`)와 Details에 알린다.
  - 자동 fetch(기본 끔, #79)는 창마다 설정 간격(최소 5분)에 한 번, 창이 key일 때만, 진행 중인 fetch가 없을 때만 실행한다. 창을 다시 활성화했을 때의 따라잡기도 간격당 한 번이다. 실제 fetch는 수동과 같은 경로(검사, 원격 상한, 저장소당 직렬화)를 지난다.
  - 그래프는 페이지 단위로 불러온다.
  - 파서는 잘린 입력을 안전하게 처리한다.
  - `fd::`는 `protocol.fd.allow=never`로 차단한다.
  - 출력 인코딩을 공통 인자 `-c i18n.logOutputEncoding=UTF-8`로 고정한다. 저장소 로컬 `i18n.logOutputEncoding`·`i18n.commitEncoding`(include 경유 포함)은 포맷된 출력 전체를 `-z` 구분자까지 다시 인코딩한다. JOHAB·CP1361은 메시지의 전각 문자(U+FF01…)를 NUL로 바꿔 필드를 밀고, 모든 검사를 통과하는 가짜 커밋 레코드를 만들 수 있다. UTF-16·UCS-4 등은 파싱을 실패시켜 그래프를 못 쓰게 만든다 (확인, E41, #205).
- **잔여 위험**: 상한 안에서도 느린 저장소는 있다. 성능 예산 문제로 다룬다. 커밋 객체의 `encoding` 헤더가 UCS-2·CP037·TCVN이면 git이 그 커밋의 모든 필드를 빈 값으로 출력해 그래프 페이지 전체가 파싱 실패한다(출력 인코딩 고정과 무관, #203 보안 검토). 필드가 밀리지는 않으므로 위조는 아니고, 가용성 문제로 남긴다.
- **검증**: SEC-T15-01 (20MB를 출력하는 테스트 실행 파일 → 상한에서 잘리고 메모리 증가가 상한 근처), SEC-T15-02 (잠자는 테스트 실행 파일 → 타임아웃 후 종료, 좀비 없음), SEC-T15-03 (잘린 입력 파서 처리), SEC-T15-06 (모든 명령이 출력 인코딩을 고정하고, JOHAB 설정 저장소에서 그래프·커밋 상세·stash 목록·기준 브랜치 비교의 커밋 목록 필드가 밀리지 않음. 대조군은 밀림), SEC-T15-07 (조회 상한을 넘는 워크트리는 `.notQueried(.limit)`이고 status가 실행되지 않음. 반복된 경로는 한 번만 나열하고, 심볼릭 링크 별칭은 한 번만 조회, #226), SEC-T15-08 (`PatchParser`가 hunk 헤더의 개수가 아니라 남은 입력만큼만 메모리를 잡음 — `+1,999999999` 헤더와 잘린 본문, #232), SEC-T15-09 (`refs/stash`에 손으로 쓴 stash가 아닌 항목(루트 커밋)이 있어도 stash 목록과 저장소 개요가 뜸. 그 항목만 기준·Includes를 모름, #71), SEC-T15-10 (원격이 많은 저장소에서 Fetch 한 번은 설정 순서로 앞의 `RepositoryService.defaultMaximumFetchedRemotes`(16)개만 fetch하고, 건너뛴 수를 상태바·Details에 알림. fetch 프로세스 수로 확인, #259), SEC-T15-11 (원격이 `feat/1-*` ref를 대량으로 밀어 넣어도 이슈 하나의 LINKED 항목은 종류별 상한까지만 만들고 나머지는 개수로만 셈. 커밋 제목은 앞부분만 훑고, LINKED 커밋 검색은 캐시해 페이지가 늘 때 새 페이지만 이어서 훑음, #82), SEC-T15-12 (원격 10만 개 + 반복 10만 개 + URL별 TLS·프록시 키 20만 개의 설정 목록을 선형 시간에 검사하고(로컬 Debug 약 1.5초, 기준 20초 — 이전 이차 시간 코드는 몇 분, #279) 상한대로 줄임. 원격 형태 검사(#350)는 모든 URL에 맞는 바꾸기 규칙 256개와 1KB 값으로 채운 약 10MB 목록에서도 기준 안에 끝남. 드라이버 257개는 조회 중단, fetch 덮어쓰기 257개는 fetch만 막음, #262), SEC-T15-13 (ISSUES의 `Check Again`을 gh가 도는 동안 여러 번 눌러도 gh를 더 띄우지 않음, #83), SEC-T15-14 (자동 fetch는 창이 key일 때만, 진행 중인 fetch 위에 겹치지 않고, 활성화 때의 따라잡기는 간격당 한 번. 실패해도 창을 바꿀 때마다 다시 시도하지 않음, #79), SEC-T15-15 (출력 상한에 잘린 파일 이력은 `Beginning of history`가 아니라 잘렸다고 표시하고, 더 요청하지 않음. 추가 페이지 실패는 Retry를 누를 때까지 다시 실행하지 않음, #70), SEC-T15-16 (그래프 검색과 사이드바 필터는 필드마다 앞부분만 훑고(제목 1,024자, 이름·ref 256자, 커밋당 co-author·ref 32개), 새 페이지가 오면 그 페이지만 이어서 훑음. ref가 바뀌면 다시 훑음, #74), SEC-T15-17 (FSEvents 자동 새로고침: 분류는 스트림 큐에서 하고 메인 액터로는 묶은 변경만 넘기며, 한 묶음이 `FileChangeClassifier.maximumEventsPerBatch`(10,000)를 넘으면 경로를 보지 않고 rescan으로 친다. 요청은 한 번에 하나, 재실행 간격 `max(2초, 소요 × 10)`, 실패한 요청은 다시 보내지 않고, 다시 보일 때도 같은 간격을 거친다. PERF-10에서 6,000개 파일 폭주 동안 status 3회, #119)
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
  - git 호환성 매트릭스(`git-compat.yml`, [ADR-0020](../adr/0020-git-compatibility-matrix-in-ci.md))는 최소 지원 버전 git을 kernel.org 공식 tarball에서 버전과 SHA-256을 고정해 받는다. 해시가 맞을 때만 러너 안에서 빌드하고, 테스트에만 쓰며, 캐시하지 않는다. 필수 검사가 아니고 `contents: read` 권한만 쓴다. Homebrew git은 러너에 있는 것만 쓰고 새로 설치하지 않는다.
- **잔여 위험**:
  - Apple 툴체인과 GitHub 러너 이미지는 신뢰한다.
  - 보드 토큰이 새면 그 계정이 쓸 수 있는 모든 Projects 보드가 바뀔 수 있다. 메인테이너 계정 토큰이면 메인테이너가 속한 조직의 보드도 포함된다. 저장소 코드와 이슈는 영향이 없다.
  - `pull_request_target`은 첫 기여자 승인 없이 실행된다. 외부 사용자가 이벤트를 많이 만들면 토큰 계정의 API 한도를 쓸 수 있다. 공유 동시성 그룹으로 상한을 둔다.
  - 호환성 매트릭스의 tarball 해시는 워크플로에 적힌 값이 신뢰의 기준이다. CI는 kernel.org 서명을 검증하지 않는다. 해시를 바꾸는 PR이 출처(`sha256sums.asc`)를 밝히고 리뷰를 거친다(ADR-0020 §4).
- **검증**: SEC-T17-01 (SPM 의존성·`Package.resolved` 없음 — `scripts/lint/check-no-dependencies.sh`와 그 테스트, CI `build-test`), SEC-T17-02 (워크플로우의 모든 `uses:`가 40자리 SHA로 고정. 같은 검사가 다음도 확인한다: 모든 워크플로우에 최상위 `permissions:`가 있고 `write-all`이 없음, `pull_request_target`은 `board-sync.yml`에만, PR·이슈 제목·본문·브랜치 이름 같은 신뢰할 수 없는 값은 `KEY: ${{ … }}` 매핑(`env:`)으로만, CI gitleaks 다운로드의 버전·SHA-256 고정 — `scripts/lint/check-workflows.sh`와 그 테스트, CI `build-test`, #95), SEC-T17-03 (Dependabot이 `/`의 `github-actions`를 갱신 — 같은 스크립트), SEC-T17-04 (`git-compat.yml`의 테스트용 git: kernel.org tarball만, `TEST_GIT_VERSION`·`TEST_GIT_SHA256` 고정, 주석이 아닌 줄에서 `TEST_GIT_SHA256`으로 검증하고 그 검증이 압축 해제·빌드보다 앞, `actions/cache` 없음 — `scripts/lint/check-workflows.sh`와 그 테스트, ADR-0020), 보드 상태 규칙은 `scripts/github/board-sync-rules.test.sh`(CI `build-test`). **수동**: `PROJECT_TOKEN`이 `project` scope 하나만 가진 토큰인지는 CI에서 볼 수 없어 메인테이너가 토큰을 바꿀 때 확인한다
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
  - 정적 연결 검사: `scripts/lint/check-secret-scanning.sh`(CI `build-test`). 두 hook이 gitleaks를 실행하고 gitleaks가 없으면 멈추는지, bootstrap이 hook을 설치하는지, CI `gitleaks` job이 PR과 main을 검사하는지, `.gitleaks.toml`이 기본 규칙과 개인 경로 규칙을 유지하는지 본다.
  - 실제 동작: `scripts/lint/check-secret-scanning.test.sh`(CI `gitleaks` job, `OVERGROVE_REQUIRE_GITLEAKS=1`). 실제 pre-commit hook이 staged 개인 경로를, pre-push hook이 push할 커밋의 개인 경로와 main push를 막는지 확인한다. 저장소 규칙이 `/Users/<이름>/`, `/home/<이름>/`, 한 글자 이름을 잡고 `runner`·`Shared`·`~/` 같은 자리표시자는 통과시키는지도 본다. gitleaks가 없는 환경(`build-test`)에서는 "gitleaks가 없으면 hook이 실패한다"만 확인한다. 샘플은 실행 중에 조립해 커밋된 문자열이 없다.
  - **#95에서 발견해 고침**: 개인 경로 규칙의 `/home/<이름>/` 절반이 동작하지 않았다. gitleaks 기본 설정(`useDefault`)의 전역 allowlist가 `/home/...`처럼 생긴 시스템 경로 비밀을 허용하기 때문이다. 규칙이 경로 전체가 아니라 `<이름>/`을 비밀로 보고하게 했다(`secretGroup`). 자리표시자 allowlist는 여전히 전체 일치를 본다.
  - **수동**: GitHub Secret scanning과 Push protection 설정은 관리자 API라 CI에서 볼 수 없다. [github-settings.md](../process/github-settings.md)의 `security_and_analysis` 조회 명령으로 확인한다(2026-11-07 확인: 둘 다 켜짐). Claude Code hook과 공개 글 승인은 하네스·절차 통제다.
- **상태**: 적용됨 (저장소 셋업, 검증 자동화 #95)

### T19. 디스크에 남는 저장소 데이터

- **설명**: 재실행 직후 첫 화면을 빨리 그리려고 조회 결과를 디스크에 남기면(#109, [ADR-0018](../adr/0018-launch-snapshot-disk-cache.md)), 앱이 닫힌 뒤에도 저장소 데이터가 사용자 계정에 남는다. 남긴 값에 자격 증명, 원격 URL, config 값, 파일 이름, 커밋 내용이 섞이면 백업·진단 수집·다른 프로세스로 새어 나갈 수 있다. 또 앱이 다음 실행 때 그 파일을 읽으므로, 바꿔 넣은 파일이 파서를 공격하거나 오래된 "안전" 결과로 git 실행을 건너뛰게 만들 수 있다.
- **대응** (ADR-0018):
  - 저장하는 필드를 전용 타입(`LaunchSnapshot`)이 정한다. 워크트리 경로, 브랜치 짧은 이름, HEAD 짧은 SHA, 개수와 상태 플래그, stash 개수만 담는다. config 값, 설정 검사 결과, 원격 이름·URL, 자격 증명, 오류 문구, 작업 트리 파일 이름, 커밋 내용, 그래프는 저장하지 않는다.
  - 표시 전용이다. 스냅샷으로 그린 동안 git이나 외부 앱을 부르는 동작을 막고, `RepoSafetyContext`·설정 검사·`TerminalGuard`·fetch 판단에 쓰지 않는다. 첫 조회는 스냅샷과 관계없이 설정 검사부터 한다.
  - 파일은 신뢰하지 않는 입력으로 읽는다. 일반 파일(링크 거부), 256 KiB 이하, 고정 스키마, 숫자·행 수·문자열 길이 상한, 절대 경로만. 하나라도 어긋나면 전체를 버리고 지운다.
  - 무효화: 형식·앱 버전, git 실행 파일 경로와 `lstat`(장치·inode·크기·mtime·ctime, 버전은 진단용 기록), 저장소 ID 해시, 공통 git 디렉터리와 워크트리 git 디렉터리 파일들의 `lstat` 지문, 7일 경과. 저장소 제거·새로고침 실패·조회 차단 때 지운다.
  - `~/Library/Caches/<bundle id>/LaunchSnapshots/`, 디렉터리 `0700`·파일 `0600`, 파일 이름은 저장소 ID의 SHA-256.
- **잔여 위험**: 워크트리 경로와 브랜치 이름은 앱이 닫힌 뒤에도 남는다. 경로는 이미 `UserDefaults`에도 있다. 같은 계정의 프로세스는 파일을 읽고 바꿀 수 있다(계정 장악은 범위 밖, §1.2). 바꿔 넣은 파일은 표시를 잠깐 속일 수 있을 뿐 명령을 실행하게 하지 못한다. `xcode-select`로 developer dir만 바꾸고 이전 git이 남아 있으면 스냅샷이 무효화되지 않아, 첫 조회 전까지 옛 숫자가 보인다(첫 조회는 지금의 git으로 한다).
- **검증** (구현 #109): SEC-T19-01 (적대적 개요 — 자격 증명 원격 URL, 토큰이 든 config 값, 설정 검사 finding, 파일 이름, 오류 문구 — 로 만든 스냅샷 JSON에 그 값들이 없음), SEC-T19-02 (손상·과대·링크·스키마 위반·범위 밖 숫자·65행 스냅샷은 버려지고 파일이 지워짐, 앱은 평소 조회로 계속), SEC-T19-03 (스냅샷 상태에서 Terminal·Finder·Compare·행 메뉴가 막히고, 스냅샷이 있어도 첫 조회가 설정 검사부터 실행됨), SEC-T19-04 (지문·버전·저장소 해시가 다르거나 7일이 지나면 보여 주지 않음, 저장소 제거 때 파일 삭제, 파일·디렉터리 권한)
- **상태**: 적용됨 (ADR-0018, #109)

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
| `GIT_ALLOW_PROTOCOL` | 기본·조회: 빈 값(전송 없음, lazy fetch 차단, #212). fetch만 명시적으로 `https:ssh:git:file:http`(내장 전송만). 기본값이 "전송 없음"이라 고르지 않은 호출부는 네트워크를 쓰지 못한다(#215). 부모 값은 무시 |
| `GIT_NO_LAZY_FETCH` | `1` (모든 명령, promisor lazy fetch 금지. 모든 경로를 막는 것은 2024년 5월 보안 릴리스(2.45.1, 2.44.1, 2.39.4·2.40.2·2.41.1·2.42.2·2.43.4)부터, #212·#317) |
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
| `^remote\..+\.(promisor\|partialclonefilter)$`, `^extensions\.partialclone$` | 전송 | **무력화**: 조회는 전송을 쓰지 않음(빈 `GIT_ALLOW_PROTOCOL`, `GIT_NO_LAZY_FETCH=1`). 누락 객체가 필요한 조회는 실패한다. fetch는 `lazyFetchControlVersion`(git 2.45.1) 이상에서만 허용(그 전에는 partial clone fetch 거부) (#212, #317) | T5 |
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
| `^i18n\.(logoutputencoding\|commitencoding)$` | 출력 | 보고 (공통 인자 `-c i18n.logOutputEncoding=UTF-8`로 고정, #205) | T15 |
| `^core\.pager$`, `^pager\..+` (값이 git 불리언이 아님) | 실행 | 보고. 앱은 `--no-pager`·`GIT_PAGER=cat`으로 쓰지 않는다. Open in Terminal 확인 사유다(#278). `pager.<cmd>=false`/`true`는 명령이 아니라 보고하지 않는다 | T14 |
| `^core\.editor$`, `^sequence\.editor$` | 실행 | 보고. 앱은 편집기를 띄우는 명령이 없다. Open in Terminal 확인 사유다(#278) | T14 |
| `^alias\..+` (값이 `!`로 시작) | 실행 | 보고. 앱은 alias를 쓰지 않는다. Open in Terminal 확인 사유다(#278) | T14 |

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
