# git 호환성 매트릭스 보고 (2026-11-08)

> 상태: 보고 · 관련: #99, ADR-0008, [security-review.md](../../design/security-review.md) §4 (E44–E46), [test-strategy.md](../../testing/test-strategy.md) §4.3, 후속 #292 (CI 매트릭스), #303 (2.36 오류 분류), #294 (Xcode 27.2 빌드 오류, #296으로 해결)

Phase 2의 보안 실험은 모두 Apple Git 2.50.1에서 했다. 최소 지원 버전 git 2.36에서도 같은지 확인하려고, 같은 테스트 전체를 여러 git으로 돌렸다.

## 1. 요약

- **판정: 보안 동작은 모든 버전에서 같다.** git 2.36.6, Apple Git 2.54.0, Homebrew git 2.54.0 어느 것에서도 canary(저장소가 설정한 프로그램)가 실행되지 않았다.
- **Apple Git과 Homebrew git은 이 장비에서 둘 다 2.54.0이다.** 그래서 실질적인 비교는 2.36.6 대 2.54.0이다. 둘 다 전체 테스트가 통과했다.
- 2.36.6에서 처음 실행했을 때 7개 테스트가 실패했다. 원인은 다음과 같다.
  - 5개: 옛 git에 없는 기능에 기대는 테스트 대조군과 픽스처 → 이 PR에서 고쳤다(§4.1).
  - 2개: 앱 동작 차이 1건. partial clone에서 쿼리가 막혔을 때 **오류 분류가 틀린다**(보안은 유지). → #303으로 분리했다(§4.2).
- 고친 뒤 다시 돌린 결과는 §3에 있다. 2.36.6에서 남은 실패는 #303의 SEC-T5-16 두 개뿐이다.
- `fetch.bundleURI`를 읽기 시작한 버전은 문서에 2.42로 적혀 있었다. 실측해 보니 **2.40**이어서 카탈로그와 주석을 고쳤다(E46).

## 2. 환경과 방법

| 항목 | 값 |
|---|---|
| 장비 | Apple M1 Pro, 10코어, 32GB, macOS 26.6.2 (25G83) |
| Xcode | 27.2 (27B52). 테스트 타깃이 이 Xcode에서 컴파일되지 않는 문제(`StatusParserTests.swift`의 긴 문자열 연결)가 있었다. 매트릭스 실행은 커밋하지 않은 임시 패치로 빌드했다. 이 오류는 #294로 등록해 #296에서 고쳤다(머지 후 임시 패치 없이 다시 빌드해 확인) |
| 커밋 | `test/99-git-compat-matrix` (기준 `main` `2658427`) |
| 테스트 | `xcodebuild test-without-building`으로 `OvergroveTests` 전체(1145개)를 돌렸다. INT·SEC만이 아니라 PAR·앱 테스트도 같은 git으로 돈다 |
| git 선택 | `TEST_RUNNER_OVERGROVE_TEST_GIT=<git 절대 경로>`, `TEST_RUNNER_OVERGROVE_TEST_GIT_VERSION=<x.y.z>` (`OvergroveTests/Support/TestGit.swift`). 기대 버전과 실제 `git version`이 다르면 git 탐색이 실패하므로 엉뚱한 git으로 통과할 수 없다. `TestGitOverrideTests.testThisRunUsesTheRequestedGit`가 각 실행에서 버전을 확인했다 |
| 픽스처 | 테스트가 고른 git으로 픽스처 스크립트도 실행한다(`FixtureRepo`가 그 git의 디렉터리를 `PATH` 앞에 둔다) |

### 2.1 git

| 이름 | 버전 | 출처 |
|---|---|---|
| Apple Git | 2.54.0 (Apple Git-157) | Xcode 27.2 개발자 디렉터리의 `usr/bin/git`. 앱이 쓰는 것과 같다(override 없음) |
| Homebrew git | 2.54.0 | 이미 설치된 `/opt/homebrew/bin/git`. 새로 설치하지 않았다(그 시점 Homebrew stable은 2.56.0) |
| git 2.36.6 | 2.36.6 | kernel.org 공식 tarball을 로컬에서만 빌드했다(§2.2). 저장소에는 아무것도 커밋하지 않았다 |
| 보조: 2.39.5, 2.40.4 | 2.39.5, 2.40.4 | 같은 방법으로 빌드했다. 2.36에서 다르게 나온 테스트의 경계 버전을 찾는 데만 썼다 |

### 2.2 git 2.36.6 빌드 (재현 방법)

| 항목 | 값 |
|---|---|
| tarball | `https://mirrors.edge.kernel.org/pub/software/scm/git/git-2.36.6.tar.xz` |
| SHA-256 | `3a54356dd0a6b23d7d0742952d5c86958ad8f797cbe41bd1952bc83ec429ea94` (같은 디렉터리의 `sha256sums.asc`와 일치. 서명 자체의 GPG 검증은 하지 않았다) |
| 보조 tarball | `git-2.39.5.tar.xz` `c58da92c378df4a986ca33266897a7397e86c22ee266a284d8c2432c39066b59`, `git-2.40.4.tar.xz` `8016dfeb9ba598a2e591270092b642ac70e65660606905277ea8e4c309b65d18` |
| 빌드 의존성 | Xcode 기본 도구만 썼다(추가 설치 없음). 약 12초 |

```sh
curl -fsSLO https://mirrors.edge.kernel.org/pub/software/scm/git/git-2.36.6.tar.xz
curl -fsSL https://mirrors.edge.kernel.org/pub/software/scm/git/sha256sums.asc | grep ' git-2.36.6.tar.xz$' | shasum -a 256 -c -
tar -xJf git-2.36.6.tar.xz && cd git-2.36.6
make -j8 prefix=~/tmp/git-2.36 NO_GETTEXT=1 NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_INSTALL_HARDLINKS=1 install
~/tmp/git-2.36/bin/git --version   # git version 2.36.6
```

### 2.3 테스트 실행

```sh
xcodebuild build-for-testing -project Overgrove.xcodeproj -scheme Overgrove -destination 'platform=macOS'
# Apple Git (앱과 같은 탐색, 버전만 확인)
TEST_RUNNER_OVERGROVE_TEST_GIT_VERSION=2.54.0 \
  xcodebuild test-without-building -project Overgrove.xcodeproj -scheme Overgrove -destination 'platform=macOS'
# Homebrew git
TEST_RUNNER_OVERGROVE_TEST_GIT=/opt/homebrew/bin/git TEST_RUNNER_OVERGROVE_TEST_GIT_VERSION=2.54.0 \
  xcodebuild test-without-building -project Overgrove.xcodeproj -scheme Overgrove -destination 'platform=macOS'
# git 2.36.6
TEST_RUNNER_OVERGROVE_TEST_GIT=~/tmp/git-2.36/bin/git TEST_RUNNER_OVERGROVE_TEST_GIT_VERSION=2.36.6 \
  xcodebuild test-without-building -project Overgrove.xcodeproj -scheme Overgrove -destination 'platform=macOS'
```

## 3. 결과

§4.1의 수정을 넣고 다시 돌린 결과다. 수정 전 첫 실행에서는 2.36.6만 7개가 실패했고, Apple Git과 Homebrew git은 그때도 모두 통과했다.

| git | 실행 | 통과 | 건너뜀 | 실패 | 소요 |
|---|---|---|---|---|---|
| Apple Git 2.54.0 | 1145 | 1138 | 7 | 0 | 325초 |
| Homebrew git 2.54.0 | 1145 | 1138 | 7 | 0 | 350초 |
| git 2.36.6 | 1145 | 1134 | 9 | 2 | 310초 |

- **건너뛴 7개**(모든 실행에서 같음): PERF opt-in 테스트다(`TEST_RUNNER_OVERGROVE_BENCH_*`, #90). `test_PERF_01`·`02`·`03`·`05`·`09`·`11`·`12`.
- **2.36.6에서 더 건너뛴 2개**: 둘 다 방어 assertion은 실행하고 대조군 일부만 건너뛴다(§4.1).
  - `PorcelainDiffConfigTests.testSECT3_03_…`: `diff.srcPrefix`·`diff.dstPrefix` 대조군에 git 2.45 이상이 필요하다.
  - `FetchRefScopeSecurityTests.testSECT13_04_…`: `fetch.bundleURI` 대조군에 git 2.40 이상이 필요하다.
- **2.36.6의 실패 2개**: `LazyFetchSecurityTests.testSECT5_16_QueriesNeverRunTheRepositoryUploadPack`, `testSECT5_16_EmptyTransportListAloneBlocksLazyFetch`. 오류 분류 차이 때문이다(§4.2, #303). canary는 실행되지 않았다.
- `TestGitOverrideTests.testThisRunUsesTheRequestedGit`는 세 실행 모두 통과했다. 각 실행이 요청한 버전의 git으로 돌았다는 뜻이다.
- 보조 실행(2.39.5, 2.40.4)에서는 `FetchRefScopeSecurityTests`, `PorcelainDiffConfigTests`, `LazyFetchSecurityTests`, `WorktreeParserTests`, `HistoryIntegrationTests`, `TestGitOverrideTests`만 돌렸다. 실패는 없었다.
  - 건너뛴 것: 2.39.5에서 SEC-T3-03·SEC-T13-04, 2.40.4에서 SEC-T3-03.
  - `fetch.bundleURI` 경계를 확인하려고 기준을 잠시 2.39로 낮춰 2.39.5에서 돌렸다. bundle 대조군이 실패했다. 그래서 기준은 2.40이다.

비교한 테스트 클래스(모든 실행에서 같다):

- INT (`OvergroveTests/Integration`, 11개): `BranchListIntegrationTests`, `ComparisonIntegrationTests`, `DiffViewerIntegrationTests`, `FileHistoryIntegrationTests`, `FixtureRepoTests`, `HistoryIntegrationTests`, `StashIntegrationTests`, `WipDetailIntegrationTests`, `WorktreeInspectionIntegrationTests`, `WorktreeListIntegrationTests`, `WorktreeStatusIntegrationTests`
- SEC (`OvergroveTests/Security`, 23개 파일): `CanaryHarnessTests`(INT-19), `ConfigExecutionArgumentTests`, `ConfigExecutionFixtureTests`, `ConfigExecutionScenarioTests`, `CredentialMaskerTests`, `FetchRefScopeSecurityTests`, `FileSystemScopeTests`, `LazyFetchSecurityTests`, `LogLeakTests`, `OutputEncodingSecurityTests`, `PathValidatorTests`, `PorcelainDiffConfigTests`, `ProcessRunnerTests`, `RemoteTransportSecurityTests`, `RepoConfigInspectorTests`, `ResourceLimitTests`, `SECT10EnvironmentTests`, `SECT11CredentialTests`, `SECT12PromptTests`, `SECT9InjectionTests`, `TrailerFormatSecurityTests`, `TransportExecutionTests`, `WriteProtectionTests`
- 그 밖에 실제 git을 쓰는 PAR(`WorktreeParserTests` 등)·앱·성능(opt-in이라 건너뜀) 테스트

## 4. 2.36.6에서 나온 차이

### 4.1 테스트의 대조군과 픽스처 (이 PR에서 고침)

| 테스트 | 2.36.6에서 실패한 이유 | 고친 방법 |
|---|---|---|
| INT-11 `HistoryIntegrationTests.testINT11_Refs` | `refs/remotes/upstream/HEAD`는 git 2.48 이상의 fetch만 자동으로 만든다. 2.36으로 만든 픽스처에는 없다 | `make-fixture-repo.sh`가 `git remote set-head upstream main`으로 직접 만든다. 모든 버전에서 같은 ref가 된다 (fixtures.md §2) |
| PAR-WT-09 `WorktreeParserTests.testPARWT09_RealGitUnbornWorktrees` | `worktree add --orphan`은 2.42부터 있다 | 2.42 미만에서는 `commit-tree`로 만든 커밋에 `--detach` 워크트리를 만들고 `symbolic-ref`로 없는 브랜치를 가리켜 같은 unborn 상태를 만든다 |
| SEC-T3-03 `PorcelainDiffConfigTests` | 대조군 `diff.srcPrefix`·`diff.dstPrefix`는 2.45부터 있다. 옛 git은 무시하므로 plain `git diff`도 바뀌지 않는다 | 앱 출력 비교(방어 assertion)는 모든 설정에서 하고, 이 두 대조군만 2.45 미만에서 건너뛴다. 끝에 XCTSkip으로 필요한 버전을 적는다 |
| SEC-T13-04 `FetchRefScopeSecurityTests` | 대조군 중 `fetch.bundleURI` 부분은 그 키를 읽는 git에서만 `refs/bundles/*`가 생긴다 | 나머지 대조군과 앱 fetch 검사는 모두 하고, bundle 대조군만 2.40 미만에서 XCTSkip. 경계는 2.39.5(대조군 실패)와 2.40.4(통과)로 실측했다 |
| `LazyFetchSecurityTests.testOldGitRefusesToFetchAPartialClone` | 실제 git이 2.44 이상이라고 가정했다. 2.36에서는 실제 fetch도 거부되는 것이 올바른 동작이다 | 실제 버전으로 분기한다. 2.44 이상은 fetch가 되고, 미만은 거부되는지 확인한다. 어느 쪽이든 canary는 실행되지 않아야 한다 |

버전 판정은 모두 테스트가 실제로 실행한 git의 `git version`(`GitEnvironment.version`)으로 한다.

### 4.2 앱 동작 차이: partial clone 쿼리의 오류 분류 (#303)

- **상황**: partial clone(`--filter=blob:none`)에서 없는 blob이 필요한 쿼리(`commitPatch` 등)를 실행한다.
- **2.44 이상**: `GIT_NO_LAZY_FETCH=1`이 lazy fetch를 끈다.
- **2.36–2.43**: 이 환경 변수를 무시한다. 대신 쿼리 환경의 빈 `GIT_ALLOW_PROTOCOL`이 lazy fetch를 막는다. **저장소의 uploadpack canary는 실행되지 않았다.** 보안 동작은 같다(SEC-T5-16의 "빈 transport 목록만으로도 막힌다"는 설계 그대로).
- **차이**: 2.36.6의 stderr는 아래뿐이다.
  ```
  fatal: transport 'file' not allowed
  fatal: transport 'file' not allowed
  fatal: unable to read <oid>
  ```
  `GitError.classify`가 이것을 `partialCloneObjectMissing`이 아니라 `transportNotAllowed`로 분류한다. 사용자는 "이 원격의 transport는 fetch하지 않는다"는 엉뚱한 안내를 보게 된다.
  - `LazyFetchSecurityTests`의 SEC-T5-16 두 테스트가 이 이유로 2.36.6에서 실패한다: `testSECT5_16_QueriesNeverRunTheRepositoryUploadPack`, `testSECT5_16_EmptyTransportListAloneBlocksLazyFetch`
  - canary 검사는 실패하지 않았다. 실패한 것은 오류 종류 검사다.
- 2.39.5와 2.40.4에서는 이 두 테스트가 통과한다. 그 버전의 stderr는 올바르게 분류된다.
- 앱 동작과 보안 분류를 바꾸는 일이라 #303으로 분리했다. CI는 2.54 계열 git을 쓰므로 영향이 없다.

## 5. 후속

- **#292**: CI에서 매트릭스를 돌린다. 2.36을 소스에서 빌드하는 것은 외부 의존성 문제라 ADR이 먼저 필요하다. 이 보고서의 `OVERGROVE_TEST_GIT` override와 빌드 명령을 그대로 쓸 수 있다.
- **#303**: 2.36의 lazy fetch stderr를 `partialCloneObjectMissing`으로 분류한다. 채집한 stderr를 픽스처로 쓴다.
