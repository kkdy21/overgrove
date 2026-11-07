# PB-2 캐시된 워크트리 간 전환 (2026-11-07)

> 상태: 측정 기록 · 관련: #88, [performance-budget.md](../performance-budget.md) PB-2, [overview.md](../../architecture/overview.md) §5

PB-2는 사이드바에서 다른 워크트리를 고른 시점부터 상세 패널과 WIP 행이 그 워크트리의 캐시 내용으로 바뀐 첫 프레임까지다(100ms p95). 백그라운드 새로고침은 포함하지 않는다. #88은 그중 **서비스 쪽**을 재고, 뷰 갱신은 워크트리 목록 화면(#65)이 그리는 시간에 맡긴다.

- **캐시 읽기**: `RepositoryService.cachedOverview(of:)` + `RepositoryOverview.snapshot(focusing:)`. 메모리만 읽고 git을 실행하지 않는다. 워크트리 10개를 차례로 고른다고 보고 1,000번 쟀다.
- **백그라운드 새로고침**: 고른 직후 `refresh(_:trigger: .worktreeSelected(path))`. 그 워크트리의 probe와 status만 실행하고(설정 검사는 지문이 같으면 캐시), 목록·refs·stash는 캐시를 쓴다. 성능 예산의 "백그라운드 status 35ms (p95)"와 비교한다. 21회 실행에서 첫 회는 버렸다.

## 환경

[PB-1 측정](2026-11-07-pb1-parallel-worktree-queries.md)과 같다. Apple M1 8코어, git 2.50.1, `make-bench-repo.sh --commit-graph`(커밋 약 8.6만, 파일 1만, 워크트리 10개). 다른 에이전트 세션들이 같은 장비에서 빌드·테스트를 함께 돌렸다. 측정 테스트는 `OvergroveTests/Performance/RepositoryOverviewBenchmarkTests.testPB2_CachedWorktreeSwitch`이고, `TEST_RUNNER_OVERGROVE_BENCH_REPO=<dir>`일 때만 실행된다.

## 결과 (5회: #226 병합 전 3회, 병합 후 2회)

| 구간 | p50 | p95 | 예산 |
|---|---|---|---|
| 캐시 읽기 + snapshot | 13µs | 14–15µs | PB-2 100ms (뷰 갱신 포함) |
| 백그라운드 선택 새로고침 | 26–28ms | 27–29ms | status 35ms |

- **캐시 읽기는 PB-2 예산의 0.02% 미만이다.** 100ms는 사실상 전부 뷰 갱신에 쓸 수 있다. 화면이 생기면(#65) 첫 프레임까지를 다시 잰다.
- **선택 새로고침은 35ms 안이다.** 실행하는 git은 probe(`rev-parse`)와 `status` 두 개다. 캐시가 없으면 여기에 `config --list`, `worktree list`, `for-each-ref`, `stash list`가 더해진다.
- 같은 실행에서 PB-1(첫 로드, 캐시 없음)은 기본 한도 8에서 p95 140–165ms였다. 이제 저장소 자체의 설정 검사(§3.2 3단계)와 워크트리 소속 확인(#226, 파일 시스템 검사)도 포함한다. 소속 확인을 더해도 차이는 잡음 안이었다.

## 결정

1. 캐시 표(overview.md §5)의 저장소 조회 행은 `RepositoryService`에 둔다. 그래프 페이지·커밋 상세·이슈 목록 행은 로더를 만드는 #68·#69·#81이 구현한다(키와 규칙은 각 이슈에 남겼다).
2. 메모리 상한: 결과 캐시는 저장소 8개, 설정 검사 캐시는 256개(저장소 × 워크트리)다. 둘 다 가장 오래 쓰지 않은 항목부터 버린다(`BoundedCache`).
3. 워크트리 선택은 디바운스하지 않는다(사용자 동작). 창 활성화와 fetch 완료는 300ms 디바운스한다.
