# 보안 테스트 통과 보고 T1–T18 (2026-11-08)

> 상태: 보고 · 관련: #97, [security-review.md](../../design/security-review.md) §2·§5.2, [process.md](../process.md) §2.2, [checklist.md](../checklist.md) QA-SEC·QA-A11Y

security-review.md가 정의한 SEC 테스트 전부의 결과와 T1–T18 잔여 위험 재검토를 한곳에 모은다. Phase 4 종료 기준(D7, "SEC 테스트 전부 통과")의 근거 자료다.

## 1. 요약

- **판정: 통과.** security-review.md의 SEC ID 88개가 모두 테스트에 연결되어 있고, `main` CI에서 전부 통과했다. 건너뛴 보안 테스트는 없다.
  - XCTest로 검증하는 ID는 83개다.
  - 나머지 T17·T18의 5개는 CI 스크립트 검사로 검증한다.
- `OvergroveTests/Security`의 24개 클래스, 161개 테스트가 모두 통과했다. INT-19(`CanaryHarnessTests`)와 악성 픽스처 대조군도 포함이다.
- **문서 ↔ 테스트 대조에 누락이 없다.** 문서에만 있고 테스트가 없는 ID는 0개다. 테스트에만 있고 문서에 없는 SEC ID도 0개다. `SEC-T15-04`·`05`는 처음부터 쓰이지 않은 번호다.
- 잔여 위험을 재검토했다. 오늘 들어온 수정으로 해소된 항목은 그대로 표시하고, **새로 찾은 잔여 위험 1건**(§5.2)을 security-review.md T14에 추가했다.

## 2. 근거

| 항목 | 값 |
|---|---|
| 커밋 | `main` `f4259bc` (#274 머지 직후) |
| CI | `ci` run [42384007320](https://github.com/kkdy21/overgrove/actions/runs/42384007320) `build-test` success: 1095 tests, 0 failures, 5 skipped(모두 PERF opt-in, #90) |
| 비밀 검사 | `secret-scan` run [42384007273](https://github.com/kkdy21/overgrove/actions/runs/42384007273) success. 로컬 `gitleaks git --no-banner --redact .` 전체 이력: no leaks found |
| GitHub 설정 | `gh api repos/kkdy21/overgrove --jq .security_and_analysis`: Secret scanning `enabled`, Push protection `enabled` (2026-11-08 조회) |
| 대조 방법 | security-review.md의 모든 `SEC-Tn-nn`(`/`로 묶은 표기 포함)을 테스트 함수 이름(`testSECTn_nn`), 함수·클래스 doc 주석, 스크립트·워크플로 참조와 맞춘 뒤, 위 CI 로그의 `Test Case … passed`와 대조했다 |

## 3. Phase 종료 점검 (security-review.md §5.2)

| 항목 | 기준 | 결과 |
|---|---|---|
| T1–T18 SEC 테스트 | 전부 통과 | ✅ 88/88 ID, 보안 클래스 161/161 |
| 악성 픽스처 | 모든 canary 미생성 | ✅ `CanaryHarnessTests.testINT19_EveryAppCommandRunsNoRepositoryConfiguredProgram`. 대조군 `testNegativeControl_PayloadsFireWithoutHardening`도 통과 |
| 인자 스냅샷 | 카탈로그와 일치 | ✅ SEC-T9-01 (8개 테스트) |
| 금지 API 검사 | 통과 | ✅ CI `ok  forbidden-API check`, SEC-T13-03 |
| gitleaks | 전체 이력 통과 | ✅ CI + 로컬 전체 이력 |
| Actions 고정 | 모든 `uses:`가 SHA | ✅ SEC-T17-02 (`check-workflows.sh`) |
| 잔여 위험 | §2 재확인과 변경 기록 | ✅ 아래 §5, security-review.md T14 갱신 |

## 4. SEC 결과표

결과는 모두 CI run 42384007320 기준이다. 테스트가 여럿이면 클래스별 개수를 적었다. 같은 테스트가 여러 ID를 검증하기도 한다.

| ID | 테스트 | 결과 |
|---|---|---|
| SEC-T1-01 | `ConfigExecutionFixtureTests.testSECT1_01_StatusRunsNoFSMonitor` | ✅ 통과 |
| SEC-T1-02 | `ConfigExecutionScenarioTests.testSECT1_02_SubmoduleFSMonitorDoesNotRun` | ✅ 통과 |
| SEC-T1-03 | `ConfigExecutionArgumentTests.testSECT1_03_EveryCommandDisablesFSMonitor` | ✅ 통과 |
| SEC-T2-01 | `ConfigExecutionFixtureTests.testSECT2_01_FetchRunsNoHook`<br>`ConfigExecutionScenarioTests.testSECT2_01_FetchRunsNoHookFromHooksDirectory` | ✅ 통과 2/2 |
| SEC-T2-02 | `ConfigExecutionArgumentTests.testSECT2_02_EveryCommandDisablesHooks` | ✅ 통과 |
| SEC-T3-01 | `ConfigExecutionFixtureTests.testSECT3_01_PatchesRunNoTextconvOrExternalDiff`<br>`ConfigExecutionScenarioTests.testSECT3_01_DiffDriverCommandDoesNotRun` | ✅ 통과 2/2 |
| SEC-T3-02 | `ConfigExecutionArgumentTests.testSECT3_02_EveryDiffCaseDisablesExternalDiffAndTextconv`<br>`ConfigExecutionFixtureTests.testSECT3_01_PatchesRunNoTextconvOrExternalDiff` | ✅ 통과 2/2 |
| SEC-T3-03 | `PorcelainDiffConfigTests.testSECT3_03_RepositoryDiffConfigurationDoesNotChangeTheOutput` | ✅ 통과 |
| SEC-T4-01 | `ConfigExecutionScenarioTests.testSECT4_01_TrackedGitattributesFilterIsNeutralized`<br>`RepoConfigInspectorFixtureTests.testSECT4_FilterPayloadRunsWithoutNeutralizationAndNotWithIt` | ✅ 통과 2/2 |
| SEC-T4-02 | `ConfigExecutionFixtureTests.testSECT4_02_InfoAttributesFilterIsNeutralized`<br>`RepoConfigInspectorFixtureTests.testSECT4_FilterPayloadRunsWithoutNeutralizationAndNotWithIt` | ✅ 통과 2/2 |
| SEC-T4-03 | `ConfigExecutionScenarioTests.testSECT4_03_RequiredFilterDoesNotBreakStatus`<br>`RepoConfigInspectorFixtureTests.testSECT4_FilterPayloadRunsWithoutNeutralizationAndNotWithIt` | ✅ 통과 2/2 |
| SEC-T4-04 | `ConfigExecutionScenarioTests.testSECT4_04_UnneutralizableDriverBlocksQueries`<br>`RepoConfigInspectorTests.testSECT4_04_UnsafeDriverNameBlocks` | ✅ 통과 2/2 |
| SEC-T4-05 | `ConfigExecutionScenarioTests` ×4 (4개) | ✅ 통과 4/4 |
| SEC-T4-06 | `TrailerFormatSecurityTests.testSECT4_06_GraphFormatReadsTrailersWithoutRunningTrailerCommands`<br>`TrailerFormatSecurityTests.testSECT4_06_control_InterpretTrailersRunsThePlantedCommand` | ✅ 통과 2/2 |
| SEC-T4-07 | `RepositoryServiceSecurityTests.testSECT4_07_worktreeConfigurationThatBlocksQueriesStopsItsStatus` | ✅ 통과 |
| SEC-T4-08 | `DiffViewerIntegrationTests.testSECT4_08_DiffViewerRunsNoPayloads` | ✅ 통과 |
| SEC-T5-01 | `TransportExecutionTests` ×7 (7개) | ✅ 통과 7/7 |
| SEC-T5-02 | `TransportExecutionTests.testSECT5_02_LocalUploadPackDoesNotRun` | ✅ 통과 |
| SEC-T5-03 | `TransportExecutionTests.testSECT5_03_ExtTransportIsRefused` | ✅ 통과 |
| SEC-T5-04 | `TransportExecutionTests.testSECT5_04_InsteadOfToExtIsRefused` | ✅ 통과 |
| SEC-T5-05 | `TransportExecutionTests.testSECT5_05_LocalGitProxyDoesNotRun` | ✅ 통과 |
| SEC-T5-06 | `TransportExecutionTests.testSECT5_06_FDTransportIsRefusedWithoutStalling` | ✅ 통과 |
| SEC-T5-07 | `TransportExecutionTests.testSECT5_07_AlternateRefsCommandDoesNotRun` | ✅ 통과 |
| SEC-T5-08 | `RemoteTransportSecurityTests` ×9, `TransportExecutionTests` ×7 (16개) | ✅ 통과 16/16 |
| SEC-T5-09 | `RemoteTransportSecurityTests.testSECT5_09_RepositoryCannotAllowItsOwnHelper` | ✅ 통과 |
| SEC-T5-10 | `RemoteTransportSecurityTests.testSECT5_10_InsteadOfCannotSwapInAHelper` | ✅ 통과 |
| SEC-T5-11 | `RemoteTransportSecurityTests.testSECT5_11_RemoteVCSDoesNotRun` | ✅ 통과 |
| SEC-T5-12 | `RemoteTransportSecurityTests.testSECT5_12_CommandLineProtocolAllowNeverIsNotEnough` | ✅ 통과 |
| SEC-T5-13 | `RemoteTransportSecurityTests.testSECT5_13_LocalPathRemoteStillFetches` | ✅ 통과 |
| SEC-T5-14 | `RemoteTransportSecurityTests.testSECT5_14_HTTPSIsNotRefusedAsATransport` | ✅ 통과 |
| SEC-T5-15 | `RemoteTransportSecurityTests.testSECT5_15_UnknownSchemeURLDoesNotRun` | ✅ 통과 |
| SEC-T5-16 | `LazyFetchSecurityTests` ×5 (5개) | ✅ 통과 5/5 |
| SEC-T6-01 | `ConfigExecutionScenarioTests.testSECT6_01_LocalGenericHelperDoesNotRun` | ✅ 통과 |
| SEC-T6-02 | `ConfigExecutionScenarioTests.testSECT6_02_LocalURLAndWildcardHelpersDoNotRun` | ✅ 통과 |
| SEC-T6-03 | `ConfigExecutionScenarioTests.testSECT6_03_TrustedGlobalHelpersRunInOrder` | ✅ 통과 |
| SEC-T6-04 | `LazyFetchSecurityTests` ×5 (5개) | ✅ 통과 5/5 |
| SEC-T7-01 | `ConfigExecutionArgumentTests.testEveryCommandDisablesSignatureDisplay`<br>`ConfigExecutionFixtureTests.testSECT7_01_GraphAndCommitMetaRunNoGPG`<br>`ConfigExecutionScenarioTests.testSECT7_01_FileHistoryRunsNoGPG` | ✅ 통과 3/3 |
| SEC-T7-02 | `ConfigExecutionArgumentTests.testSECT7_02_NoSignatureFormatInSources` | ✅ 통과 |
| SEC-T8-01 | `ConfigExecutionFixtureTests.testSECT8_01_FetchStartsNoAutoMaintenance` | ✅ 통과 |
| SEC-T8-02 | `ConfigExecutionArgumentTests.testSECT8_02_EveryCommandDisablesAutoGCAndMaintenance` | ✅ 통과 |
| SEC-T9-01 | `GitCommandTests` ×5, `SECT9InjectionTests` ×3 (8개) | ✅ 통과 8/8 |
| SEC-T9-02 | `GitArgumentsTests` ×5, `SECT9InjectionTests` ×3 (8개) | ✅ 통과 8/8 |
| SEC-T9-03 | `HostilePathTests.testSECT9_03_HostileFileNamesAreLiteral`<br>`SECT9InjectionTests.testSECT9_03_HostileFileNamesThroughGitClient` | ✅ 통과 2/2 |
| SEC-T9-04 | `GitArgumentsTests` ×5, `SECT9InjectionTests` ×3 (8개) | ✅ 통과 8/8 |
| SEC-T9-05 | `GitHubRemoteTests.testRejectsEverythingElse` | ✅ 통과 |
| SEC-T10-01 | `GitEnvironmentTests` ×12, `SECT10EnvironmentTests` ×2 (14개) | ✅ 통과 14/14 |
| SEC-T10-02 | `GitEnvironmentTests` ×12, `SECT10EnvironmentTests` ×2 (14개) | ✅ 통과 14/14 |
| SEC-T10-03 | `GHClientTests` ×3, `SECT10EnvironmentTests` ×2 (5개) | ✅ 통과 5/5 |
| SEC-T11-01 | `CredentialMaskerTests` ×10, `SECT11CredentialTests` ×2 (12개) | ✅ 통과 12/12 |
| SEC-T11-02 | `SECT11CredentialTests` ×2, `FetchFailureGuidanceTests`, `FetchFailureTests` (4개) | ✅ 통과 4/4 |
| SEC-T11-03 | `RepoConfigInspectorTests.testSECT11_03_LocalSSLVerifyIsAlwaysForcedTrue`<br>`SECT11CredentialTests.testSECT11_03_LocalSSLVerifyFalseIsTrueForFetch`<br>`SECT11CredentialTests.testSECT11_04_RemoteURLShownWithoutCredentials` | ✅ 통과 3/3 |
| SEC-T11-04 | `SECT11CredentialTests.testSECT11_04_RemoteURLShownWithoutCredentials`<br>`WorktreeDetailModelTests.testSECT11_04_RemoteURLCredentialsAreMasked`<br>`WorktreeInspectionIntegrationTests.testSECT11_04_NormalFixtureShowsOnlyTheMaskedRemote` | ✅ 통과 3/3 |
| SEC-T11-05 | `SECT11CredentialTests` ×2, `GHClientTests`, `GHCommandTests` (4개) | ✅ 통과 4/4 |
| SEC-T12-01 | `SECT12PromptTests.testSECT12_01_RepositoryAskPassNeverRuns` | ✅ 통과 |
| SEC-T12-02 | `SECT12PromptTests.testSECT12_02_MissingCredentialsFailFastAsAuthentication` | ✅ 통과 |
| SEC-T13-01 | `WriteProtectionTests` ×6, `GitCommandTests` ×5 (11개) | ✅ 통과 11/11 |
| SEC-T13-02 | `WriteProtectionTests` ×4, `ConfigExecutionArgumentTests` (5개) | ✅ 통과 5/5 |
| SEC-T13-03 | `WriteProtectionTests.testSECT13_03_ForbiddenAPICheckGuardsProcessCreation` | ✅ 통과 |
| SEC-T13-04 | `FetchRefScopeSecurityTests.testSECT13_04_RepositoryConfigCannotWidenWhatFetchWrites`<br>`GitCommandTests.testSECT13_04_FetchPinsItsRefspecAndPruneScope` | ✅ 통과 2/2 |
| SEC-T13-05 | `IssueModelsTests.testBrowserURLIsOnlyAGitHubIssuePage` | ✅ 통과 |
| SEC-T14-01 | `FileSystemScopeTests` ×3, `PathValidatorTests`, `RepositoryRegistrarTests` (5개) | ✅ 통과 5/5 |
| SEC-T14-02 | `FileSystemScopeTests` ×3, `PathValidatorTests` ×2 (5개) | ✅ 통과 5/5 |
| SEC-T14-03 | `BareRepositoryRegistrationTests.testBareRepositoryWithCoreWorktreeRegistersAsBareAndIsReported`<br>`FileSystemScopeTests.testSECT14_03_IncludedCoreWorktreeIsReported`<br>`FileSystemScopeTests.testSECT14_03_LocalCoreWorktreeIsReported` | ✅ 통과 3/3 |
| SEC-T14-04 | `BareRepositoryRegistrationTests` ×9, `RepositoryRegistrarTests` ×2 (11개) | ✅ 통과 11/11 |
| SEC-T14-05 | `RepositoryServiceSecurityTests.testSECT14_05_coreWorktreeInWorktreeConfigurationIsNotQueried`<br>`RepositoryServiceSecurityTests.testSECT14_05_folderBorrowingALinkedWorktreeEntryIsNotQueried`<br>`RepositoryServiceSecurityTests.testSECT14_05_forgedEntryForAMainWorktreeSubfolderIsNotQueried` | ✅ 통과 3/3 |
| SEC-T14-06 | `DiffViewerIntegrationTests.testSECT14_06_UntrackedFIFOAndEscapingLinkAreNotPreviewed` | ✅ 통과 |
| SEC-T14-07 | `RowActionsTests` ×3, `AppStateNavigationTests` (4개) | ✅ 통과 4/4 |
| SEC-T14-08 | `TerminalGuardTests.testListedKeysAreMaskedAndCapped`<br>`TerminalGuardTests.testOpenInTerminalOpensCleanAndConfirmsTheRest`<br>`TerminalGuardTests.testReasons` | ✅ 통과 3/3 |
| SEC-T15-01 | `ProcessRunnerTests.testSECT15_01_StdoutIsCappedAndMarkedTruncated`<br>`ResourceLimitTests.testSECT15_01_OutputIsCappedAndMemoryStaysNearTheCap` | ✅ 통과 2/2 |
| SEC-T15-02 | `ProcessRunnerTests.testSECT15_02_TimeoutTerminatesAndLeavesNoZombie`<br>`ResourceLimitTests.testSECT15_01_OutputIsCappedAndMemoryStaysNearTheCap`<br>`ResourceLimitTests.testSECT15_03_TruncatedRealOutputParsesToAPrefix` | ✅ 통과 3/3 |
| SEC-T15-03 | `WorktreeParserTests` ×26, `RefParserTests` ×25, `ResourceLimitTests` (52개) | ✅ 통과 52/52 |
| SEC-T15-06 | `OutputEncodingSecurityTests` ×5, `ConfigExecutionArgumentTests` (6개) | ✅ 통과 6/6 |
| SEC-T15-07 | `RepositoryServiceSecurityTests.testSECT15_07_queriesStopAtTheLimit`<br>`RepositoryServiceSecurityTests.testSECT15_07_repeatedAndAliasedFoldersAreQueriedOnce` | ✅ 통과 2/2 |
| SEC-T15-08 | `PatchParserTests.testSECT15_08_HugeHunkCountOverShortBody` | ✅ 통과 |
| SEC-T15-09 | `StashIntegrationTests.testSECT15_09_NonStashReflogEntryKeepsTheOverviewLoading` | ✅ 통과 |
| SEC-T15-10 | `RepositoryServiceFetchTests.testSECT15_10_FetchTakesAtMostTheRemoteLimit` | ✅ 통과 |
| SEC-T15-11 | `IssueLinkTests.testLinksPerIssueAreLimited` | ✅ 통과 |
| SEC-T15-12 | `RepoConfigInspectorTests.testSECT15_12_HugeListingIsInspectedInLinearTime` | ✅ 통과 |
| SEC-T15-13 | `AppStateIssueTests.testCheckAgainDoesNotPileUpGh` | ✅ 통과 |
| SEC-T15-14 | `AutoFetchSchedulerTests.testSECT15_14_ActivationCatchUpIsBounded` | ✅ 통과 |
| SEC-T16-01 | `LogLeakTests.testSECT16_01_LogsContainNoCredentialsOrRawRemoteURLs` | ✅ 통과 |
| SEC-T17-01 | `scripts/lint/check-no-dependencies.sh` + `.test.sh` (CI `build-test` › Validate repository tooling: `ok  no third-party dependencies`) | ✅ 통과 (스크립트) |
| SEC-T17-02 | `scripts/lint/check-workflows.sh` + `.test.sh` (CI `build-test`: `ok  workflows: pinned actions, minimal permissions, untrusted input via env, Dependabot`) | ✅ 통과 (스크립트) |
| SEC-T17-03 | 같은 스크립트 (Dependabot `github-actions` at `/`) | ✅ 통과 (스크립트) |
| SEC-T18-01 | `scripts/lint/check-secret-scanning.sh` + `.test.sh` (CI `build-test`), `secret-scan.yml` run 42384007273 success, 로컬 `gitleaks git` 전체 이력 유출 없음 | ✅ 통과 (스크립트) |
| SEC-T18-02 | 같은 스크립트의 개인 경로 규칙 샘플 (`check-secret-scanning.test.sh`) | ✅ 통과 (스크립트) |

## 5. 잔여 위험 재검토

### 5.1 위협별

| 위협 | 문서의 잔여 위험 | 재검토 결과 |
|---|---|---|
| T1 fsmonitor | 없음 (확인된 범위) | **유지.** 앱 밖 경로인 Open in Terminal은 #73의 `TerminalGuard`가 로컬 `core.fsmonitor`를 보면 확인을 받는다 (SEC-T14-08) |
| T2 hooks | 없음 (확인된 범위) | **유지.** `.git/hooks`의 실행 파일은 설정 보고에 나오지 않는다. 하지만 `TerminalGuard`가 직접 찾아 확인 사유로 쓴다(#73). fetch 실패 안내(T5)의 남는 위험은 그대로다 |
| T3 external diff·textconv | 새 diff 명령에서 인자 누락 가능 → SEC-T3-02가 모든 diff case 열거 | **유지.** #239로 저장소 diff 설정이 porcelain 출력을 바꾸는 경로를 막았다 (SEC-T3-03) |
| T4 filters | global 필터는 신뢰 범위. 로컬 LFS 무력화 시 변경으로 보일 수 있음 | **유지.** 해소된 것: 서브모듈 필터(#238·#239, SEC-T4-05), 위조 워크트리 항목(#221·#226, SEC-T4-07·SEC-T14-05), Diff 뷰어 경로(#232, SEC-T4-08). SEC-T4-01 대조군 간헐 실패는 #273(#274)으로 결정적이 되었다 |
| T5 전송 | 로컬 경로 원격의 상대 저장소 설정, `ftp`, 커스텀 helper, global gitProxy 무시, 터미널 안내 | **유지.** 해소된 것: promisor 설정에 의한 lazy fetch(#212, SEC-T5-16·SEC-T6-04), 원격 개수 상한(#261, SEC-T15-10), fetch refspec·prune 범위 고정(#209, SEC-T13-04). 로컬 경로 원격은 #107(신뢰하지 않음 모드)에 남는다 |
| T6 credential helper | 신뢰 scope helper 자체 위험 (위협 모델 밖) | **유지** |
| T7 서명 프로그램 | 없음 | **유지** |
| T8 auto gc·maintenance | 없음 | **유지** |
| T9 인자 인젝션 | 낮음 | **유지.** 해소된 것: 저장소 i18n 설정에 의한 `-z` 필드 밀림(#205, SEC-T15-06, 출력 인코딩 고정). 기준 ref는 `--end-of-options` 뒤(#157, SEC-T9-01) |
| T10 환경 상속 | `HOME` 공유, gh 경로 TOCTOU (모델상 수용) | **유지** |
| T11 자격 증명 노출 | 새 토큰 형식 미검출 가능 | **유지.** 후속 #244(스킴 없는 config subsection의 접두어 없는 토큰 마스킹)가 열려 있다 |
| T12 프롬프트 대기 | 신뢰 sshCommand에 BatchMode 없으면 타임아웃까지 대기 | **유지.** BatchMode의 호스트 키 프롬프트 차단은 §4.2의 "확인하지 못한 것"이다. 수동 QA로 확인한다 |
| T13 쓰기 명령 | 낮음. #208·#209 수정 | **해소 확인.** #211(index 재작성 차단, SEC-T13-02)과 #209(SEC-T13-04)가 CI에서 통과했다 |
| T14 범위 이탈 | alternates, Open in Terminal 셸 | **갱신.** 행 메뉴(SEC-T14-07)와 `TerminalGuard`(SEC-T14-08)를 반영했다. 새 잔여 위험(§5.2)은 #278에서 **해소**했다(SEC-T14-10) |
| T15 자원 고갈 | 느린 저장소, UCS-2 등 `encoding` 헤더 커밋으로 그래프 페이지 파싱 실패 | **유지.** 해소된 것: 설정 검사 작업량 상한(#262, SEC-T15-12), 워크트리 개수 상한(#226, SEC-T15-07). index가 오래된 상태의 느린 status는 PB-5 밖 시나리오로, #168이 안내한다 |
| T16 로그 | 개발 장비의 private 로그 | **유지.** QA-SEC-06으로 수동 확인한다 |
| T17 공급망 | Apple·러너 이미지 신뢰, 보드 토큰 범위, `pull_request_target` 이벤트 남용 | **유지.** 새 워크플로 `perf.yml`(#271)은 SHA 고정, `contents: read`, PR 이벤트 없음으로 `check-workflows.sh`를 통과한다 |
| T18 비밀 커밋 | 규칙 밖 형식 | **유지.** 설정은 오늘 다시 확인했다(§2) |

### 5.2 새로 찾은 잔여 위험

**Open in Terminal 확인 조건이 앱이 실행하지 않는 키를 보지 못한다 (T14, #73 후속) — #278(PR #281)에서 해소.** 검사기가 아래 키들을 T14로 보고하고, `TerminalGuard`는 모든 finding을 확인 사유로 쓴다(SEC-T14-10). 아래는 발견 당시의 기록이다.
- `TerminalGuard`는 설정 검사의 T1–T7 finding, 차단, 실행 가능한 hook을 본다. 그런데 `RepoConfigInspector`는 앱이 실행하지 않는 키를 보고 대상에 넣지 않는다. 해당하는 키는 `core.pager`·`pager.<cmd>`, `core.editor`·`sequence.editor`, `!`로 시작하는 `alias.*`다.
- threat가 없는 finding(`submodule.<n>.update=!cmd`, `uploadpack.packObjectsHook`)도 확인 조건에서 빠진다.
- 프롬프트 플러그인의 `git status`는 이 키들을 쓰지 않는다. 하지만 사용자가 그 터미널에서 `git log`(pager), `git commit`(editor), `git submodule update`를 직접 실행하면 저장소가 정한 명령이 돈다. 확인 창은 뜨지 않았다.
- **영향**: 사용자가 직접 명령을 입력해야 하므로 프롬프트 플러그인 경로보다 낮다. fetch 실패 안내(T5)의 `pager.*` 남는 위험과 같은 종류다.
- **제안(후속 이슈 후보)**: 검사기가 이 키들을 `reported`(threat T3 또는 새 분류)로 보고하게 한다. `TerminalGuard`는 threat 없는 finding도 확인 사유로 넣는다. S-05 SECURITY 표시와 fetch 안내의 "보고가 깨끗함" 판정도 함께 좋아진다.

## 6. 수동 항목

CI로 볼 수 없어 사람이 확인하는 항목이다. Phase 4 QA(#96)와 함께 기록한다.

| 항목 | 근거 | 상태 |
|---|---|---|
| Secret scanning·Push protection 설정 (T18) | 관리자 API | ✅ 2026-11-08 조회: 둘 다 enabled |
| `PROJECT_TOKEN`이 `project` scope 하나뿐인지 (T17) | 토큰 scope는 CI에서 보이지 않음 | 메인테이너 확인 필요 (토큰을 바꿀 때) |
| QA-SEC-01–07 (악성 픽스처 화면 전수, fetch, S-05 표시, 마스킹, 로그, 심볼릭 링크 미리보기) | [checklist.md](../checklist.md) | #96 |
| QA-A11Y-10 (Open in Terminal 확인 창, `⏎`·`⎋` 모두 Cancel) | 같은 문서 | #96 |
| `ssh -o BatchMode=yes`의 호스트 키 프롬프트 차단 (T12) | security-review.md §4.2 | #96 수동 QA |

## 7. 열린 후속

| 이슈 | 위협 | 내용 |
|---|---|---|
| #244 | T11 | 스킴 없는 config subsection의 접두어 없는 토큰 마스킹 |
| #107 | T5 | 신뢰하지 않음 모드 (로컬 경로 원격의 `upload-pack` 차단 등) |
| #195 | T13 | 저장소 로컬 `fetch.bundleURI` 보고 |
| #168 | T15 (가용성) | index가 오래된 상태의 느린 status 안내 |
| #254 | T15 (가용성) | commit-graph 없는 저장소의 그래프 스트리밍 |
| #153 | T10 | 셸 프록시 환경 변수 전달 여부 결정 |
| #108 | T1·T4 | 서브모듈 상태를 안전하게 조회 |
| #34 | T17 | CodeQL Swift 분석 |
| ~~(제안)~~ #278 | T14 | §5.2: 앱이 실행하지 않는 실행 키 보고와 Open in Terminal 확인 조건 확대. 해소 (PR #281) |
