# ADR-0020: git 호환성 매트릭스를 CI에서 돌리는 방법

> 상태: Accepted · 날짜: 2026-11-08 · 관련: #292, #99, ADR-0006, ADR-0008, [design/security-review.md](../design/security-review.md) T17, [testing/test-strategy.md](../testing/test-strategy.md) §4.3·§10

## 맥락

#99에서 최소 지원 버전 git 2.36, Apple Git, Homebrew git으로 INT·SEC 테스트를 로컬에서 한 번 돌렸다([보고서](../qa/reports/2026-11-08-git-compatibility.md)). 그 과정에서 버전에 따라 달라지는 결함을 세 건 찾았다(#303, #317). 앞으로도 같은 종류의 회귀를 잡으려면 CI에서 같은 매트릭스를 주기적으로 돌려야 한다.

문제는 git 2.36을 얻는 방법이다.

- Homebrew에는 2.36 버전 formula가 없다.
- 공식 배포는 소스 tarball뿐이다.
- 외부에서 받은 코드를 CI에서 빌드하고 실행하는 일이라 ADR-0006(외부 의존성 0개)과 T17(공급망)에 걸린다.
- test-strategy.md §10이 이 결정을 ADR로 미뤄 두었다.

## 결정

호환성 매트릭스는 **필수 검사가 아닌 별도 워크플로**(`.github/workflows/git-compat.yml`)로 돌린다. git 2.36은 **kernel.org 공식 tarball을 버전과 SHA-256으로 고정해 받아 CI 러너 안에서 빌드**하고, 테스트에만 쓴다.

### 1. 매트릭스

| 항목 | git을 얻는 방법 |
|---|---|
| Apple Git | 러너에서 고른 Xcode의 `usr/bin/git`. 앱과 같은 탐색이고, 테스트용 git 지정(override) 없이 돌린다 |
| Homebrew git | 러너 이미지에 이미 있는 `$(brew --prefix)/bin/git`. **새로 설치하지 않는다.** 없으면 그 항목은 실패한다 |
| git 2.36.6 | 공식 tarball을 받아 SHA-256이 맞을 때만 빌드한다(§2) |

- 각 항목은 `TEST_RUNNER_OVERGROVE_TEST_GIT_VERSION`에 기대 버전을 준다. Apple과 Homebrew는 실제 `git --version`에서 읽고, 2.36은 고정값을 준다. 실제 버전이 다르면 git 탐색 자체가 실패한다(#99의 `TestGit`).
- 워크플로는 `TestGitOverrideTests.testThisRunUsesTheRequestedGit`가 **통과**했는지 로그에서 확인한다. 건너뛰었거나 실패했으면 그 항목을 실패로 처리한다. 다른 git으로 조용히 도는 일을 막기 위해서다.
- 실행하는 테스트는 `OvergroveTests/Integration`·`OvergroveTests/Security`의 모든 테스트 클래스, 그리고 실제 git을 쓰는 `TestGitOverrideTests`와 `WorktreeParserTests`다. 앱 전체 테스트는 `ci.yml`이 맡는다.

### 2. git 2.36 받기와 빌드

- **출처**: `https://mirrors.edge.kernel.org/pub/software/scm/git/git-<버전>.tar.xz`
- **고정**: 워크플로에 `TEST_GIT_VERSION`과 `TEST_GIT_SHA256`을 적는다. 내려받은 파일을 `shasum -a 256 -c`로 검증하고, **맞지 않으면 빌드하지 않고 멈춘다.** `scripts/lint/check-workflows.sh`가 두 값의 고정과 검증 단계가 있는지를 확인한다(SEC-T17-04).
- **빌드**: 러너에서 고른 Xcode의 기본 도구만 쓴다.
  - 옵션은 `make NO_GETTEXT=1 NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_INSTALL_HARDLINKS=1`이다(#99 보고서와 같음).
  - 설치 위치는 `$RUNNER_TEMP` 아래이고, 작업이 끝나면 러너와 함께 사라진다.
- **용도**: 테스트 전용이다. 앱이나 릴리스 산출물에 들어가지 않는다.
- **캐시하지 않는다.** 빌드는 1분 안팎이다. 캐시를 쓰면 PR 실행이 쓴 캐시를 main 실행이 읽는 경로가 생긴다(캐시 오염). 매번 검증된 tarball에서 다시 빌드한다.
- **비밀 정보와 권한**: 워크플로는 `permissions: contents: read`만 갖고, 비밀 정보를 쓰지 않는다. Action은 기존과 같은 `actions/checkout`과 `actions/upload-artifact`를 전체 커밋 SHA로 고정해 쓴다.

### 3. 실행 시점

- 주 1회 schedule로 main에서 돈다.
- `workflow_dispatch`로 수동 실행할 수 있다.
- git 호출·실행·파서·보안 코드, 그 테스트, 테스트 지원 코드, 픽스처 스크립트, 이 워크플로 자체를 바꾼 PR에서도 돈다.

**필수 검사가 아니다.** 실패는 PR에 보이지만 머지를 막지 않는다. macOS 러너 시간이 들고, 러너 이미지가 바뀌면(Homebrew git이 빠지는 경우 등) 코드와 무관하게 실패할 수 있기 때문이다. 실패하면 원인을 보고 이슈로 다룬다.

### 4. 고정값 갱신 절차

`TEST_GIT_VERSION`과 `TEST_GIT_SHA256`은 함께 바꾼다. 바꾸는 경우는 최소 지원 버전이 바뀔 때, 또는 같은 계열의 보안 릴리스가 나올 때다.

- 해시는 같은 디렉터리의 `sha256sums.asc`에서 가져온다.
- 가능하면 그 파일의 서명을 로컬에서 확인하고, 그 사실을 PR에 적는다.
- CI는 서명을 검증하지 않는다. 워크플로에 적힌 해시가 신뢰의 기준이고, 그 해시는 PR 리뷰를 거친다.

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| Homebrew에서 특정 버전 설치 | 빌드가 없다 | 2.36 formula가 없다. tap을 추가하면 서드파티 공급망이 생긴다 | 불가능, T17 |
| git 저장소를 clone해 태그를 빌드 | 서명된 태그 | clone이 크고 느리다. 태그를 신뢰하려면 서명 검증 체계가 필요하다 | tarball + 해시가 더 단순하다 |
| 빌드한 git을 캐시 | 빠르다 | 캐시 오염 경로가 생긴다. 빌드가 이미 짧다 | 얻는 것이 작다 |
| 빌드한 바이너리를 저장소에 커밋 | 빌드가 없다 | 리뷰할 수 없는 바이너리가 들어온다(T17, ADR-0006) | 금지 |
| 필수 검사로 둔다 | 회귀를 확실히 막는다 | 시간·비용이 든다. 러너 이미지 변화로 무관한 실패가 난다 | 주기 실행 + PR 경로 실행으로 충분하다 |
| 로컬 1회 검증만 한다(#99) | 비용이 없다 | 회귀를 계속 잡지 못한다 | 이 ADR의 목적 |

## 결과

- 최소 지원 git과 최신 git 사이의 동작 차이를 매주, 그리고 관련 코드를 바꾼 PR마다 확인한다.
- 외부에서 받는 것은 공식 tarball 하나다. 해시가 고정되어 있어 내용이 바뀌면 빌드 전에 멈춘다.
- macOS 러너 시간이 더 든다. 매트릭스 3개, 관련 경로 PR과 주 1회다.
- Homebrew git의 버전은 러너 이미지를 따라간다. 고정하지 않고 실행할 때마다 기록한다.
- 다시 검토할 조건:
  - 최소 지원 버전이 바뀔 때
  - 러너 이미지에서 Homebrew git이 빠질 때
  - 매트릭스가 자주 무관하게 실패할 때

## 후속 작업

- [x] `.github/workflows/git-compat.yml`, `scripts/lint/check-workflows.sh`의 SEC-T17-04 검사 (#292)
- [x] security-review.md T17, test-strategy.md §4.3·§10 갱신 (#292)
