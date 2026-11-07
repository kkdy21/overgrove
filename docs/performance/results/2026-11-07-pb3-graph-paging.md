# PB-3 그래프 첫 페이지와 페이지 비용 (2026-11-07)

> 상태: 측정 기록 · 관련: #68, #89, [ADR-0010](../../adr/0010-commit-graph-layout-in-app.md), [performance-budget.md](../performance-budget.md) PB-3·PB-3b·PB-4

#68이 구현한 그래프 페이지(`graphPage(skip:limit:)` = `log --exclude=refs/stash --all --date-order -z <형식> --skip=<n> -n 500`)의 비용을 쟀다. #89(페이지 방식 결정)의 근거 자료다.

## 환경

[PB-1 측정](2026-11-07-pb1-parallel-worktree-queries.md)과 같은 장비와 저장소다. Apple M1 8코어, git 2.50.1, `make-bench-repo.sh --commit-graph`. `--all`로 보이는 커밋은 68,734개다.
- 앱 경로 측정: `OvergroveTests/Performance/GraphBenchmarkTests`(`TEST_RUNNER_OVERGROVE_BENCH_REPO=<dir>`). 프로세스 실행과 파싱을 포함하고 렌더링은 뺐다. 첫 페이지는 21회 실행에서 첫 회를 버렸다.
- commit-graph 유무 비교: 같은 인자로 git을 직접 실행했다(`-c core.commitGraph=true|false`, 3회). 시간 측정 도구의 오버헤드가 약 20ms 섞여 있다.

## 결과

**앱 경로 (commit-graph 있음, 2회)**

| 항목 | 값 |
|---|---|
| 첫 페이지 500개 | p50 41–47ms, **p95 48–49ms** (PB-3 500ms) |
| `--skip=500` / `10000` / `40000` 페이지 | 중앙값 39–50ms (깊이와 무관) |
| 전체 이력을 한 프로세스로(`-n 100000`) | 918–1,075ms (68,734개) |
| 모든 페이지 레이아웃(`GraphEngine`, 이어 계산) | 합계 약 640ms, **가장 느린 페이지 5ms** |

**commit-graph 유무 (git 직접, ms)**

| skip | commit-graph 있음 | 없음 |
|---|---|---|
| 0 | 67–71 | 430–471 |
| 10,000 | 68–70 | 457–463 |
| 40,000 | 69–71 | 448–469 |
| 68,000 | 65–73 | 442–471 |
| 전체 한 번(`-n 100000`) | — | 665–667 |

## 해석

- **PB-3는 크게 여유가 있다.** commit-graph가 있으면 첫 페이지 git+파싱이 p95 약 50ms다. 없으면 약 450ms로 보조 예산 PB-3b(1.0초) 안이다.
- **`--skip`은 깊이에 따라 느려지지 않는다.** 비용은 건너뛴 커밋 수가 아니라 `--date-order` 정렬이다. commit-graph가 있으면 정렬이 싸서 어느 페이지든 약 50ms다. 없으면 페이지마다 전체를 다시 걸어 약 450ms가 든다.
- **commit-graph가 없을 때만 스트리밍이 이긴다.** 68,734개를 다 보려면 `--skip` 페이지는 138번 × 약 450ms다. 한 프로세스로 읽으면 전체 약 670ms다. 첫 500개가 보이는 시점은 둘이 비슷하다(정렬이 끝나야 출력이 시작된다).
- **PB-4(스크롤 60fps)**: 메인 액터에서 하는 일은 페이지당 레이아웃 5ms 이하와 행 추가뿐이다. 페이지 읽기는 백그라운드이고, 끝에서 100행(3,000pt) 전에 미리 시작한다. commit-graph가 있으면 50ms 안에 도착하므로 빠른 스크롤에서도 끊기지 않는다. commit-graph가 없으면 450ms 사이에 3,000pt보다 빨리 스크롤하면 끝에서 잠깐 기다릴 수 있다. 프레임 드롭이 아니라 다음 페이지 대기다.

## 제안 (#89)

1. v0.1은 지금 구현한 `--skip`/`-n` 페이지(`GraphLoading` 뒤)를 유지한다. 단순하고, ref 집합 단위로 캐시되며, commit-graph가 있는 일반적인 저장소에서는 충분히 빠르다.
2. commit-graph가 없는 큰 저장소를 위해 스트리밍 로더(한 프로세스의 출력을 페이지 단위로 소비)를 후속으로 둔다. `GraphLoading`을 바꿔 끼우면 되고, 화면과 `GraphStore`는 그대로다.
3. ADR-0010의 "페이지 방식 재검토" 항목을 위 결정으로 갱신한다(#89에서).
