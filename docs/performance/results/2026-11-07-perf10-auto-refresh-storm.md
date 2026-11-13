# PERF-10 자동 새로고침 이벤트 폭주 (#119)

> 측정: 2026-11-07, Apple M1, git 2.54.0, Debug 빌드 테스트 실행 · 관련: [performance-budget.md](../performance-budget.md) PB-10, [interaction.md §4](../../design/interaction.md), #163

## 시나리오

- 정상 픽스처(`scripts/make-fixture-repo.sh`)를 연다. 검증된 워크트리 8개, 공통 git 디렉터리를 감시한다.
- 실제 FSEvents, 실제 `AutoRefreshController`, 실제 `RepositoryService`를 쓴다. git 대리 실행 파일이 하위 명령 수를 센다.
- 메인 워크트리의 `node_modules/`에 파일 6,000개를 8초 동안 40번에 나눠 쓴다(`npm install`이나 에이전트 빌드처럼).
- 마지막 쓰기 후 6초를 더 기다린다.

재현: `TEST_RUNNER_OVERGROVE_PERF=1 xcodebuild test … -only-testing:OvergroveTests/AutoRefreshBenchmarkTests`

## 결과

| 항목 | 값 |
|---|---|
| 경과 | 15.9초 |
| 새로고침 요청 | 3회 (상한: 경과/2초 + 1 = 9) |
| `git status` 실행 | 3회 (요청마다 바뀐 워크트리 하나만) |
| 새로고침 소요 | 61 / 79 / 50ms |
| git CPU (자식 프로세스 user+sys) | 0.11초, 한 코어의 0.7% |

## 해석

- 처음 구현은 마지막 이벤트 뒤 1초 디바운스만 했다. 그래서 폭주 8초 동안 한 번도 새로고침하지 않고 끝난 뒤 1회만 했다. 쉬지 않고 파일을 쓰는 에이전트를 지켜볼 때 화면이 멈춘 것처럼 보이는 문제여서, **최대 대기 5초**를 넣었다. 이벤트가 계속 와도 첫 변경 후 5초 안에 요청한다. 그 결과가 위 표다.
- 재실행 간격 max(2초, 소요 × 10)은 이 픽스처에서 2초다(소요 50–80ms). index가 오래된 10만 개 저장소처럼 status가 5초 걸리면 간격이 50초가 되어 한 코어의 약 10%로 묶인다(#163 측정 근거). 단위 테스트 `testOneAtATimeWithTheReRunGap`이 이 계산을 확인한다.
- 보안 검토 후(분류를 스트림 큐로 옮기고 묶음 상한·메인 액터 호출 병합을 넣은 뒤) 다시 쟀다(2026-11-08): 경과 15.7초, 요청 3회, status 3회, 소요 46 / 80 / 49ms, git CPU 0.7%. 결과는 같다.
- 앱 자신의 git 호출은 감시 대상 이벤트를 만들지 않는다(`AutoRefreshIntegrationTests.testOwnQueriesProduceNoRelevantEvents`, 실제 FSEvents).

## 남은 측정

- 실제 대형 저장소(bench 저장소, index 오래됨)에서의 폭주는 `OVERGROVE_BENCH_REPO` 환경에서 따로 잰다. 이 PR에서는 하지 않았다.

## 비교 카드 (#581, 2026-11-13)

S-02·S-05 아래 비교 카드는 포커스 워크트리를 S-11 기본 비교(미커밋 포함)로 비교한다. status가 새로 읽히면 캐시 키(`statusQueried`)가 바뀌어 비교를 다시 돈다. 같은 장비, git 2.54.0, Debug 빌드에서 쟀다.

| 측정 | 결과 |
|---|---|
| 폭주 + 새로고침마다 카드 비교(디바운스·간격 없음, 상한), 픽스처 | 경과 15.6초, 새로고침 2회, status 2회, 카드 비교 2회. git 명령: diff 2, log 2, rev-list 2, rev-parse 4, status 2. 새로고침 36·54ms, 비교 32·28ms. git CPU 0.15초(한 코어의 0.9%, 카드 없을 때 0.7%) |
| bench 저장소(`make-bench-repo.sh` 기본값: 커밋 10만, 파일 1만, 워크트리 10), 연결 워크트리, 선택 새로고침 직후 비교 20회 | status p50 32.6ms / p95 34.7ms, 비교(캐시 빗나감) p50 648ms / p95 677ms |

- 비교 횟수는 새로고침 횟수를 넘지 않는다. 하지만 큰 저장소에서는 비교 한 번이 status의 약 20배다. 2초마다 새로고침하는 동안 매번 비교하면 한 코어의 약 33%가 된다.
- 그래서 자동 새로고침이 가져온 카드 비교는 직전 비교가 끝난 뒤 max(5초, 소요 × 10)을 기다린다(위 bench에서 약 6.5초, 한 코어의 약 10%). 자동 새로고침 자신의 규칙(재실행 간격 max(2초, 소요 × 10))과 같은 방식이다. 사용자 동작은 300ms 디바운스만 거친다.
- 재현: `TEST_RUNNER_OVERGROVE_PERF=1 xcodebuild test … -only-testing:OvergroveTests/AutoRefreshBenchmarkTests/testPERF10_CompareCardDuringTheStorm`, `TEST_RUNNER_OVERGROVE_BENCH_REPO=<dir> … -only-testing:OvergroveTests/RepositoryOverviewBenchmarkTests/test_PERF_10b_compareCardVersusStatus`
