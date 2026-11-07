# PERF-13 실행 간 스냅샷 진행 조건 (2026-11-08)

> 상태: 측정 기록 · 관련: #109, [ADR-0018 §7](../../adr/0018-launch-snapshot-disk-cache.md), [benchmark-plan.md](../benchmark-plan.md) PERF-13, [performance-budget.md](../performance-budget.md) PB-1

ADR-0018은 실행 간 스냅샷을 만들기 전에 이득을 재고, 재실행 첫 워크트리 목록이 p95 150ms 이상 빨라지지 않으면 구현을 멈추기로 했다. 이 문서가 그 측정이다.

## 무엇을 쟀나

재실행하면 앱은 마지막 저장소를 빈 캐시로 연다. 사이드바는 첫 `.user` 조회가 끝나야 그려진다. 스냅샷은 그 기다림을 작은 파일 하나 읽기로 바꾼다. 앱 프로세스 시작, 창 생성, 행 그리기는 두 경우가 같으므로 다른 부분만 쟀다.

| 측정 | 내용 |
|---|---|
| 스냅샷 없음 | 재실행이 목록을 그리기 전에 하는 일: git 찾기(`GitEnvironment.discover`), 새 `GitClient`·`RepositoryService`(빈 캐시), bench 저장소의 첫 `.user` 조회(워크트리 목록, 워크트리 10개의 확인·설정 검사·status, refs, stash) |
| 스냅샷 읽기 | ADR-0018 §1 필드를 담은 시제품 형식 파일: `lstat`(일반 파일·크기 확인), 읽기, JSON 디코딩, 범위 검사(§4), §3 지문(`HEAD`, `packed-refs`, `config`, `worktrees/`, `index`, 연결 워크트리마다 `HEAD`·`index`의 `lstat`). 10행과 상한 64행 |

시제품 형식은 측정용이고 앱의 타입이 아니다. 실제 `LaunchSnapshot`도 같은 필드와 같은 검사를 하므로 비용은 같은 크기로 본다.

## 환경

| 항목 | 값 |
|---|---|
| 장비 | Apple M1 Pro, 10코어, macOS 26.6.2 |
| git | Xcode 개발자 디렉터리의 git, 앱과 같은 인자·환경, 격리한 HOME |
| 저장소 | `scripts/make-bench-repo.sh --commit-graph`. 커밋 약 10만, 추적 파일 1만, 워크트리 10개(각각 WIP 변경) |
| 측정 | `OvergroveTests/Performance/LaunchSnapshotBenchmarkTests`, `TEST_RUNNER_OVERGROVE_BENCH_REPO=<dir>`, `TEST_RUNNER_OVERGROVE_PERF_REPORT_ONLY=1`. 스냅샷 없음은 21회, 읽기는 201회, 첫 회는 워밍업으로 버림. nearest-rank p95 |
| 주의 | 다른 에이전트 세션들이 같은 장비에서 빌드·테스트를 돌렸다(load average 5–11). 그래서 세 번 쟀다 |

## 결과

| 회차 | 스냅샷 없음 p50 / p95 | 10행 읽기 p95 | 64행 읽기 p95 | **이득 (p95 차)** |
|---|---|---|---|---|
| 1 (load 5.7) | 170 / 180 ms | 513 µs | 1.4 ms | **179 ms** |
| 2 (load 11.0) | 164 / 185 ms | 517 µs | 1.2 ms | **184 ms** |
| 3 (load 10.3) | 161 / 169 ms | 488 µs | 1.2 ms | **168 ms** |

- 파일 크기: 10행 약 9.4 KB, 64행 약 26 KB(상한 256 KiB의 10분의 1).
- 세 번 모두 이득이 150ms 이상이다(168–184ms). **진행 조건을 통과했다.** 다만 여유는 20–35ms다.
- 스냅샷 읽기는 1ms 안팎이라 이득은 거의 전부 "첫 조회를 기다리지 않는 것"에서 온다. 그래서 이득은 저장소 크기와 워크트리 수에 따라 커진다. 이 장비보다 빠른 장비나 작은 저장소에서는 150ms보다 작을 수 있다.
- 측정하지 않은 것: 이 결과 위에 얹히는 앱 쪽 처리(목록 모델 만들기, 그리기)는 두 경우가 같다고 보고 뺐다. UI 테스트 타깃이 생기면 첫 프레임으로 다시 잰다(benchmark-plan.md §3.1).

## 결정

ADR-0018 §7의 진행 조건을 통과했으므로 #109에서 `LaunchSnapshot`을 구현한다. 여유가 작으므로 구현 PR에서 실제 타입으로 다시 잰다.

## 실제 타입으로 다시 잰 결과 (구현 후)

시제품 대신 `LaunchSnapshotStore.load`(모든 §3·§4 검사, git 실행 파일과 지문의 `lstat`)와 사이드바 행 만들기(`WorktreeListModel(snapshot:)`)를 쟀다. 같은 장비, 같은 저장소다.

| 회차 | 스냅샷 없음 p50 / p95 | 10행 읽기 p95 | 64행 읽기 p95 | **이득 (p95 차)** |
|---|---|---|---|---|
| 1 (load 9.5) | 167 / 184 ms | 723 µs | 2.4 ms | **183 ms** |
| 2 (load 8.9) | 175 / 187 ms | 766 µs | 2.6 ms | **187 ms** |
| 3 (load 12.1) | 173 / 191 ms | 776 µs | 2.8 ms | **191 ms** |

- 파일 크기: 10행 약 7.9 KB, 64행 약 26 KB.
- 실제 타입은 시제품보다 읽기가 약 0.25ms 느리다(행 모델 만들기 포함). 이득은 183–191ms로 진행 조건을 계속 만족한다.
