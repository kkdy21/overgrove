# 성능 예산 검증 보고 PB-1–PB-9 (2026-11-08)

> 상태: 보고 · 관련: #98, [performance-budget.md](../../performance/performance-budget.md), [benchmark-plan.md](../../performance/benchmark-plan.md) §3·§7, [process.md](../process.md) §2.2, [보안 테스트 보고](2026-11-08-security-test-pass.md)

Phase 4 종료 기준(D9, "PB-1–PB-8 충족")의 근거 자료다. 오늘(2026-11-07) 들어온 측정 기록과 PERF 테스트(#90, 이 PR의 PERF-11·12)를 한 장비에서 다시 돌려 PB마다 p95를 모았다.

## 1. 요약

- **판정: 측정한 범위에서 위반 없음.**
  - PB-1·2·3·3b·7·8·9는 앱 경로(git 실행 + 파싱 + 서비스, 렌더링 제외)를 쟀고 모두 예산 안이다. 가장 빠듯한 것은 PB-7이다(p95 430ms / 1.0초).
  - PB-4는 UI 없는 대리 측정으로, PB-5는 서비스의 선택 새로고침과 git 계층으로 판정했다.
  - PB-6은 GraphEngine 레이아웃의 메모리만 쟀다.
- **재지 않은 것**(§4): 화면 첫 프레임과 스크롤 hitch(XCUITest 없음), 앱 전체 메모리(PB-6), 대형 untracked·10만 파일·index가 오래된 상태의 status. index가 오래된 상태는 예산을 넘지만 performance-budget.md가 PB-5 판정에서 빼고 #168로 관리한다.
- **미달로 새로 만들 이슈: 없음.** 남은 위험은 이미 열린 이슈(#168, #91, #254, #275)가 덮는다.
- PB-10(FSEvents 자동 새로고침)은 #275가 아직 열려 있어 예산과 측정 테스트가 main에 없다. #275가 들어오면 이 표에 더한다.

## 2. 환경

| 항목 | 값 |
|---|---|
| 장비 | Apple M1, 8코어, 16GB, macOS 26.5.2 (기준 측정 기록들과 같은 장비) |
| git | Xcode 개발자 디렉터리의 `usr/bin/git` 2.50.1 (Apple Git-155), 앱과 같은 인자·환경, 격리한 HOME |
| 커밋 | `main` `8fe0a7f` + 이 PR의 PERF-11·12 테스트 |
| 저장소 | `scripts/make-bench-repo.sh --commit-graph`: 커밋 약 10만(`--all`로 보이는 커밋 68,734), 추적 파일 1만, 워크트리 10, stash 5. PB-3b용으로 `--commit-graph` 없이 만든 같은 저장소 |
| 방법 | `benchmark-plan.md` §7. `TEST_RUNNER_OVERGROVE_BENCH_REPO`, `TEST_RUNNER_OVERGROVE_PERF=1`, `TEST_RUNNER_OVERGROVE_PERF_REPORT_DIR`. 21회 실행에서 첫 회는 버리고 nearest-rank p95(합성 입력은 11회) |
| 부하 | 다른 에이전트 세션의 빌드·테스트가 함께 돌았다(load average 2.6–6.2). 이전 기록과 비교해 흔들림은 수 ms 안이다 |

## 3. PB별 결과

| 예산 | 시나리오 | 목표 (p95) | 측정 (p95) | 판정 | 출처 |
|---|---|---|---|---|---|
| PB-1 | 저장소 열기 → 워크트리 10개 목록·상태 | 1.0초 | **152ms** (기본 조회 한도 8; 한도 1이면 350ms) | ✅ (렌더링 제외) | PERF-01 |
| PB-2 | 캐시된 워크트리 전환 | 100ms | **29µs** (캐시 읽기 + snapshot). 백그라운드 선택 새로고침 33.6ms (status 기준 35ms) | ✅ (뷰 갱신 제외) | PERF-02 |
| PB-3 | 그래프 첫 페이지 500개, commit-graph 있음 | 500ms | **41.7ms**. 깊은 페이지(`--skip` 1만·4만)도 중앙값 39–41ms | ✅ (렌더링 제외) | PERF-03 |
| PB-3b | 같은 것, commit-graph 없음 | 1.0초 | **408ms**. 페이지마다 약 404ms(전체를 다시 걸음) | ✅ | PERF-03 (commit-graph 없는 bench) |
| PB-4 | 그래프 스크롤 60fps | 프레임 드롭 없음 | 페이지 레이아웃(메인 액터) 최대 **4.9ms**(실제 bench 138페이지), 합성 10만 커밋 최대 **6.4ms** / 프레임 16.7ms | ✅ (대리 측정) | PERF-03, PERF-05 |
| PB-5 | 파일 1만 개 워크트리 status 새로고침 | 300ms | 선택 새로고침(probe + status, 추적 파일 1만) **33.6ms**. git status 단독 30ms(S1) | ✅ (렌더링 제외) | PERF-02, [2026-11-06 S1](../../performance/results/2026-11-06-apple-git-2.54.md) |
| PB-6 | 커밋 10만 개 적재 시 메모리 | 300MB 이하 | GraphEngine 레이아웃 10만 커밋: 테스트 프로세스 peak physical **137MB** | ⚠️ 부분 측정 (§4) | PERF-04 (`GRA-09`, `XCTMemoryMetric`) |
| PB-7 | 파일 이력(S-09) 첫 100개 | 1.0초 | **430ms** (`--follow`, 앱 경로: 워크트리 재확인 + 설정 검사 포함) | ✅ (렌더링 제외) | PERF-11 (신규) |
| PB-8 | 커밋·stash 상세 파일 목록 | 200ms | 커밋(캐시 안 됨) **16.6ms**, stash **20.9ms** | ✅ (렌더링 제외) | PERF-12 (신규) |
| PB-9 | Diff 뷰어 파일 하나(1만 줄 이하) | 200ms, 첫 프레임 16ms | 1만 줄 파싱+행 **68.3ms**, 첫 프레임 **9.4ms**(10MB diff도 9.4ms) | ✅ | PERF-09, [S-10 기록](../../performance/results/2026-11-07-s10-diff-viewer.md) |

오늘의 측정 기록과 비교(같은 장비):

| 예산 | 기록 (2026-11-07) | 이번 |
|---|---|---|
| PB-1 | p95 135–165ms ([pb1](../../performance/results/2026-11-07-pb1-parallel-worktree-queries.md)) | 152ms |
| PB-2 | 14–15µs, 새로고침 27–29ms ([pb2](../../performance/results/2026-11-07-pb2-cached-worktree-switch.md)) | 29µs, 33.6ms |
| PB-3 | 48–49ms, commit-graph 없으면 430–471ms(git 직접) ([pb3](../../performance/results/2026-11-07-pb3-graph-paging.md)) | 41.7ms, 408ms(앱 경로) |
| PB-9 | 70ms, 첫 프레임 9.5ms ([S-10](../../performance/results/2026-11-07-s10-diff-viewer.md)) | 68.3ms, 9.4ms |

co-author trailer 파싱 비용 기록([co-author](../../performance/results/2026-11-07-co-author-trailers.md))은 PB-3 첫 페이지 측정에 이미 포함된다(그래프 포맷에 `%(trailers)`가 들어 있음).

## 4. 재지 않은 것과 남은 위험

| 항목 | 상태 | 관련 |
|---|---|---|
| 화면 첫 프레임 (PB-1·2·3·5·7·8) | 렌더링을 뺀 계층만 쟀다. 예산의 대부분(PB-1 850ms 이상)이 렌더링 몫으로 남는다. XCUITest·signpost 측정은 UI 테스트 타깃이 생긴 뒤 | benchmark-plan §3 |
| PB-4 hitch ratio | 메인 액터 페이지 비용만 쟀다. 실제 스크롤 hitch는 XCUITest가 필요하다 | benchmark-plan §3 PERF-05 |
| PB-6 앱 전체 메모리 | 레이아웃만 쟀다(137MB, 테스트 호스트 포함). 10만 커밋 메타데이터를 모델로 들고 있는 앱 전체의 peak는 재지 않았다. 앱은 페이지 단위로 읽으므로 전체 적재는 끝까지 스크롤할 때만 생긴다 | PERF-07(benchmark-plan의 PB-6 앱 전체 메모리)은 미구현 |
| PB-5: index가 오래된 상태 | 파일 1만 개의 mtime만 바뀌면 git status p95 **328ms**로 300ms를 넘는다(S3a, 10만 개는 5.8초). performance-budget.md가 PB-5 판정에서 빼고 안내로 대응하기로 했다 | #168 (열림) |
| PB-5: untracked 수만 개 | git 시간은 47ms(2만 개)로 작지만 출력이 383KB다. 파싱·모델 비용은 재지 않았다 | #91 (열림) |
| PB-5: 추적 파일 10만 개 | git status 170ms(S2)로 예산 안. 워크트리 10개가 모두 이 크기면 PB-1 내부 목표(500ms)가 빠듯하다 | 2026-11-06 기록 |
| PB-3b 전체 이력 | commit-graph 없는 저장소에서 끝까지 스크롤하면 페이지마다 약 400ms가 든다. 프레임 드롭이 아니라 다음 페이지 대기다 | #254 (스트리밍, 열림) |
| PB-10 FSEvents 자동 새로고침 | 예산과 측정 테스트가 #275에 있고 아직 머지되지 않았다 | #275 |
| 최소 지원 git 2.36, Homebrew git | 재지 않았다 | benchmark-plan §6 |

## 5. 이 PR에서 더한 측정

- `OvergroveTests/Performance/DetailBenchmarkTests.swift`
  - PERF-11: `LiveFileHistoryLoader`로 첫 페이지.
  - PERF-12: `LiveCommitLoader.detail`(캐시에 없는 비병합 커밋 20개)과 `LiveStashLoader.files`.
  - bench 저장소에서만 돈다(opt-in).
  - bench 브랜치 끝의 최신 비병합 커밋 21개는 파일을 바꾸지 않는다(워크트리 준비용). 그래서 PERF-12는 그 뒤의 커밋을 쓴다.
- benchmark-plan.md §3·§3.1·§7과 `perf.yml`에 PERF-11·12를 더했다.
  - PERF-07(PB-6 메모리)·08(git 기준선)은 이미 정의된 번호이고, 10번은 #275가 쓴다. 그래서 11·12를 골랐다.
