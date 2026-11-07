# PB-1 워크트리 10개 병렬 조회 (2026-11-07)

> 상태: 측정 기록 · 관련: #87, [performance-budget.md](../performance-budget.md) PB-1·§4 권고 2, [overview.md](../../architecture/overview.md) §3.2·§4

`RepositoryService.loadOverview`가 PB-1의 git 계층을 한 번에 실행하는 데 걸린 시간을 쟀다. 실행 순서는 `worktree list` 다음에 워크트리별 `status`, `for-each-ref`, `stash list`를 병렬로 돌리는 것이다. 조회 동시 실행 한도(`GitClient`의 조회 풀)를 바꿔 가며 비교했다.

## 환경

| 항목 | 값 |
|---|---|
| 장비 | Apple M1, 8코어, macOS 26.5.2 |
| git | Xcode 개발자 디렉터리의 `usr/bin/git` 2.50.1 직접 실행. 앱과 같은 인자·환경(`GitEnvironment`), 격리한 HOME |
| 저장소 | `scripts/make-bench-repo.sh --commit-graph`. 커밋 약 8.6만, 추적 파일 1만, 워크트리 10개(메인 + `wt-00`–`wt-08`, 각각 WIP 변경 포함) |
| 측정 | `OvergroveTests/Performance/RepositoryOverviewBenchmarkTests`, `TEST_RUNNER_OVERGROVE_BENCH_REPO=<dir>`. 한도마다 21회 실행, 첫 회는 워밍업으로 버림. nearest-rank p95. 프로세스 생성·파싱 포함, 렌더링 제외 |
| 주의 | 같은 장비에서 다른 에이전트 세션이 함께 돌았다. 두 번 측정했다 |

## 결과 (ms)

| 조회 한도 | 1회차 p50 | 1회차 p95 | 2회차 p50 | 2회차 p95 |
|---|---|---|---|---|
| 1 | 247 | 254 | 248 | 255 |
| 4 (이전 기본값) | 129 | 136 | 135 | 152 |
| **8 (새 기본값, min(코어, 8))** | 132 | 155 | 125 | 138 |
| 10 | 117 | 131 | 124 | 133 |

- **PB-1(1.0초 p95)을 크게 밑돈다.** 기본값으로 git 계층과 파싱은 p95 약 140–155ms다. 렌더링에 850ms 이상이 남고, 내부 목표 500ms 안이다.
- 직렬(한도 1) 대비 병렬이 약 2배 빠르다.
- 4와 8의 차이는 같은 장비 반복 잡음(±10%, §1) 안이다. 4를 넘으면 이득이 작다는 §4 권고 2의 관찰과 맞는다.

## 결정

- 조회 한도의 기본값을 **min(코어, 8), 최소 2**(`GitClient.defaultConcurrency`)로 바꾼다(#87 완료 조건). 이 장비에서는 8이다. 4 대비 손해가 없고, 코어가 적은 장비에서는 코어 수를 넘겨 디스크를 다투지 않는다.
- fetch는 지금처럼 별도 풀(앱 전체 2개)이다. 그래서 git 프로세스는 동시에 최대 min(코어, 8) + 2개다. 조회는 fetch를 기다리지 않는다(#76).
- 저장소 하나의 조회 묶음은 `RepositoryService`가 시작하고, 동시 실행 수는 `GitClient`가 정한다. 여러 저장소나 워크트리가 동시에 새로고침해도 한도는 앱 전체에 한 번만 적용된다.
