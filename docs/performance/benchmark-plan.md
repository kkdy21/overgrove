# 벤치마크 계획

> 상태: Accepted (Phase 2 게이트, 2026-11-05) · 관련: [performance-budget.md](performance-budget.md), [test-strategy.md](../testing/test-strategy.md), ADR-0008, ADR-0010

[성능 예산](performance-budget.md)을 어떻게 재고, 회귀를 어떻게 잡는지 정한다. 앱이 없는 지금도 쓸 수 있는 git 계층 측정 도구와, Phase 3 이후의 앱 측정 방법을 함께 다룬다.

---

## 1. 도구

| 도구 | 용도 | 시점 |
|---|---|---|
| [`scripts/make-bench-repo.sh`](../../scripts/make-bench-repo.sh) | 대형 기준 저장소 생성 (결정적) | 지금 |
| [`scripts/measure-git-baseline.sh`](../../scripts/measure-git-baseline.sh) | git 계층 비용 측정, Markdown 표 출력 | 지금 |
| [`scripts/measure-git-scenarios.sh`](../../scripts/measure-git-scenarios.sh) | 기준선에 없는 시나리오: 파일 10만 개, index가 오래된 상태, untracked 대량, 브랜치 ahead/behind, 설정 검사. 기준 저장소를 바꾼다 | 지금 |
| XCTest `measure(metrics:)` | `XCTClockMetric`, `XCTCPUMetric`, `XCTMemoryMetric`, `XCTOSSignpostMetric` | Phase 3 |
| `os_signpost` | 앱 내부 구간 표시 (저장소 열기, status 배치, 그래프 첫 페이지, 레인 계산) | Phase 3 |
| Instruments | Time Profiler, Allocations, SwiftUI, Hitches, os_signpost 템플릿 | Phase 3 이후 원인 분석 |

외부 벤치마크 라이브러리는 쓰지 않는다 (ADR-0006).

---

## 2. 기준 저장소 만들기

```sh
scripts/make-bench-repo.sh --commit-graph ~/tmp/overgrove-bench           # 기본: 커밋 10만, 파일 1만, 워크트리 10
scripts/make-bench-repo.sh ~/tmp/overgrove-bench-nograph                   # commit-graph 없는 조건 (PB-3b)
scripts/make-bench-repo.sh --commits 3000 --files 500 --worktrees 4 <dir>  # 스크립트 확인용 소형
```

| 항목 | 기본값 실측 |
|---|---|
| 생성 시간 | 약 30초 (fast-import 18초 + 워크트리 체크아웃). commit-graph 쓰기는 +3초 |
| 커밋 | 100,024 (병합 2,782) |
| 브랜치 / 태그 | `main` + `lane/00`–`lane/11` / `bench-10000` … `bench-100000` |
| 추적 파일 | 10,000 (`src/dNN/fNNNNN.txt`) |
| 워크트리 | 10 (`repo/` + `worktrees/wt-00`–`wt-08`) |
| 워크트리별 변경 | staged 5, unstaged 15, untracked 10 |
| ahead/behind | `main` +1/-2, `lane/NN`은 (n mod 3, (n+1) mod 3) |
| stash | 5개 |
| `.git` 크기 | 62MB |

생성 방식은 다음과 같다.
- awk가 만든 스트림을 `git fast-import`로 한 번에 넣는다.
- 의사 난수는 Park–Miller LCG(seed 42)다. 그래서 같은 옵션이면 항상 같은 이력이 나온다.
- `lane/00`, `lane/01`은 병합되지 않는 장수 브랜치다. 나머지 레인은 5–44커밋 뒤 `main`에 병합되고 다시 시작한다. 그래서 어느 시점이든 레인 10개 안팎이 동시에 살아 있어 그래프 레인 부하가 생긴다.
- 병합 커밋의 트리는 `main` 쪽을 따른다. 내용 병합은 흉내 내지 않는다. 그래프와 이력 조회 부하가 목적이기 때문이다.

---

## 3. 측정 항목 (PERF)

| ID | 측정 | 연결 예산 | 방법 | 시점 |
|---|---|---|---|---|
| PERF-01 | 저장소 열기 → 워크트리 목록·상태 요약 첫 프레임 | PB-1 | XCUITest 실행 + signpost `open-repo` 구간 | Phase 3 |
| PERF-02 | 캐시된 워크트리 전환 | PB-2 | XCUITest + signpost `switch-worktree` | Phase 3 |
| PERF-03 | 그래프 첫 페이지 (commit-graph 있음/없음) | PB-3, PB-3b | signpost `graph-first-page` | Phase 3 |
| PERF-04 | GraphEngine 레인 계산 (10만 커밋, UI 없음) | PB-3 내부 | XCTest `measure` + `XCTClockMetric`, `XCTMemoryMetric` (GRA-09) | Phase 3 |
| PERF-05 | 그래프 스크롤 hitch ratio | PB-4 | XCUITest swipe + `XCTOSSignpostMetric.scrollDecelerationMetric` | Phase 3 |
| PERF-06 | status 새로고침 (파일 1만 개) | PB-5 | signpost `refresh-status` | Phase 3 |
| PERF-07 | 10만 커밋 적재 시 최대 메모리 | PB-6 | `XCTMemoryMetric` | Phase 3 |
| PERF-08 | git 계층 기준선 (B01–B18) | 전체 하한 | `measure-git-baseline.sh` | 지금, git 버전 변경 시 |
| PERF-09 | Diff 뷰어 파싱·행·첫 프레임 (500줄, 1만 줄, 약 10MB) | PB-9 | XCTest, 합성 patch | Phase 3 |
| PERF-10 | 자동 새로고침 중 파일 쓰기 폭주 (파일 6,000개를 8초 동안, #119) | PB-10 | XCTest, 실제 FSEvents + 표준 픽스처, git 호출 기록 | Phase 3 |
| PERF-11 | 파일 이력(S-09) 첫 100개 (`--follow`) | PB-7 | XCTest, bench 저장소 (#98) | Phase 4 |
| PERF-12 | 커밋·stash 상세(S-03, S-04) 파일 목록 | PB-8 | XCTest, bench 저장소 (#98) | Phase 4 |

### 3.1 지금 있는 XCTest (#90)

UI 계층(첫 프레임, hitch)은 아직 재지 않는다. 아래 테스트는 그 아래 계층(git, 파싱, 서비스, 레이아웃)을 예산에 대어 본다. 화면 측정(XCUITest, signpost)은 UI 테스트 타깃이 생기면 같은 ID에 더한다.

| ID | 테스트 (`OvergroveTests/Performance/`) | 입력 | 판정 |
|---|---|---|---|
| PERF-01 | `RepositoryOverviewBenchmarkTests.test_PERF_01_tenWorktreeOverview` | bench 저장소, 조회 한도 1·4·기본·10 | 기본 한도 p95 < 1.0초 (PB-1, 렌더링 제외) |
| PERF-02 | `RepositoryOverviewBenchmarkTests.test_PERF_02_cachedWorktreeSwitch` | bench 저장소, 캐시 읽기 1,000회 | 캐시 읽기 p95 < 100ms (PB-2, 뷰 제외). 선택 새로고침은 status 35ms와 참고 비교 |
| PERF-03 | `GraphBenchmarkTests.test_PERF_03_graphFirstPageAndPaging` | bench 저장소 | 첫 페이지 p95 < 500ms (PB-3). commit-graph가 없으면 < 1.0초 (PB-3b). 페이지별 레이아웃 최대 < 16.7ms |
| PERF-04 | `GraphEnginePerformanceTests.test_GRA_09_*` | 합성 이력 10만 | `XCTClockMetric`, `XCTMemoryMetric` 기준값(`.xcbaseline`). 항상 실행 |
| PERF-05 | `GraphBenchmarkTests.test_PERF_05_pageLayoutFitsAFrame` | 합성 이력 10만 | 스크롤 중 메인 액터가 하는 페이지 레이아웃 최대 < 16.7ms (PB-4 대리 측정). hitch ratio는 XCUITest 이후 |
| PERF-11 | `DetailBenchmarkTests.test_PERF_11_fileHistoryFirstPage` | bench 저장소, 파일 하나의 `--follow` 이력 | 첫 페이지(100) p95 < 1.0초 (PB-7, 렌더링 제외) |
| PERF-12 | `DetailBenchmarkTests.test_PERF_12_commitAndStashFileLists` | bench 저장소, 캐시에 없는 커밋 20개와 최신 stash | 각각 p95 < 200ms (PB-8, 렌더링 제외) |
| PERF-09 | `DiffViewerBenchmarkTests.test_PERF_09_diffRendering` | 합성 patch | 1만 줄 이하 파싱+행 p95 < 200ms, 모든 크기 첫 프레임 p95 < 16ms (PB-9) |
| PERF-10 | `AutoRefreshBenchmarkTests.testPERF10_EventStormKeepsStatusRunsBounded` | 표준 픽스처, `node_modules`에 파일 6,000개 | 요청 ≤ 경과/2초 + 1, status 실행 = 요청 수 (PB-10). git CPU는 기록만 |

모든 테스트는 `PERF-nn RESULT` 표를 출력한다. 예산을 넘으면 실패한다(`OVERGROVE_PERF_REPORT_ONLY=1`이면 표에만 적는다). 반복 횟수와 p95 계산은 [performance-budget.md §1](performance-budget.md)을 따른다. 21회 실행에서 첫 회를 버리고, nearest-rank로 구한다.

signpost 이름은 `subsystem = io.github.kkdy21.overgrove`, `category = performance`로 통일한다. 구간 이름은 위 표의 영문 식별자를 쓴다. signpost 메시지에 경로, 저장소 이름, 브랜치 이름을 넣지 않는다 (T16).

---

## 4. git 계층 기준선 (실측)

측정 환경은 다음과 같다.
- 장비: Apple M1 Pro (10코어), 32GB, macOS 26.6
- git: `/usr/bin/git` 2.50.1 (Apple Git-155)
- 저장소: `make-bench-repo.sh` 기본값
- 반복: 20회, nearest-rank, 단위 ms, 프로세스 생성 비용 포함
- 인자와 환경: git-command-catalog §2의 공통 인자와 환경 변수

| ID | 항목 | A: shim, graph 없음 p50 / p95 | B: shim, graph 있음 p50 / p95 | C: 직접 실행, graph 있음 p50 / p95 | 출력 |
|---|---|---|---|---|---|
| B01 | `worktree list --porcelain -z` | 17 / 18 | 17 / 18 | 9 / 11 | 2KB |
| B02 | status v2 (메인 워크트리 1개) | 35 / 35 | 35 / 37 | 27 / 27 | 3KB |
| B03 | status v2 × 10 순차 | 349 / 364 | 350 / 353 | 267 / 271 | — |
| B04 | status v2 × 10 병렬 (동시 10) | 152 / 181 | 164 / 184 | 159 / 173 | — |
| B05 | `rev-list` ahead/behind × 10 순차 | 164 / 169 | 163 / 167 | 83 / 89 | — |
| B06 | `for-each-ref` heads/remotes/tags | 19 / 20 | 19 / 21 | 11 / 11 | 3KB |
| B07 | `stash list` | 21 / 22 | 21 / 24 | 13 / 13 | 0.4KB |
| B08 | `log` 첫 500개 `--date-order` | **406 / 416** | **47 / 49** | 38 / 39 | 76KB |
| B09 | `log` 첫 500개 기본 순서 | 24 / 24 | 23 / 25 | 15 / 15 | 76KB |
| B10 | `log` 전체 메타데이터 `--date-order` | 559 / 574 | 546 / 558 | 539 / 547 | 15.1MB |
| B11 | `show --numstat HEAD` | 16 / 17 | 16 / 17 | 8 / 9 | — |
| B12 | `log --follow` 첫 100개 | **656 / 675** | 383 / 392 | 380 / 389 | 1KB |
| B13 | `log -- <path>` 첫 100개 | 142 / 153 | 23 / 25 | 15 / 17 | — |
| B14 | `stash show --numstat` | 18 / 21 | 18 / 19 | 10 / 11 | — |
| B15 | `diff --numstat` (워크트리 대 인덱스) | 28 / 29 | 28 / 29 | 19 / 20 | — |
| B16 | `diff --cached --numstat` | 18 / 19 | 18 / 19 | 10 / 12 | — |
| B17 | `rev-list --count --all` | **394 / 413** | 39 / 48 | 30 / 32 | — |
| B18 | `log` 500개 페이지 `--skip=50000` `--date-order` | **403 / 419** | 49 / 50 | 40 / 41 | 76KB |

"shim"은 `/usr/bin/git`, "직접 실행"은 `xcrun --find git`이 돌려준 실제 경로(`/Library/Developer/CommandLineTools/usr/bin/git`)를 뜻한다.

### 4.1 추가 측정

| 측정 | 결과 |
|---|---|
| 실행 파일별 `rev-parse HEAD` (p50 / p95) | `/usr/bin/git` 15 / 16ms, CLT 직접 7 / 7ms, Homebrew git 2.54 10 / 11ms. `DEVELOPER_DIR`을 지정해도 shim 비용은 같다 |
| status × 10 병렬도별 (직접 실행, p50 / p95) | 1: 269 / 271, 2: 203 / 210, 4: 163 / 172, 6: 151 / 159, 10: 128 / 167ms |
| 그래프 전체 스트리밍 중 첫 76KB(약 500개) 도착 | graph 있음 39ms, 없음 390ms |
| `--skip` 위치별 페이지 비용 (직접 실행) | graph 있음: skip 0 34ms → 99,000 42ms. 없음: 모든 위치 약 395ms (매번 전체를 다시 걸음) |
| racy index 영향 | bench 생성 직후와 `update-index --refresh` 뒤의 status 차이 없음 (35ms) |

### 4.2 해석

1. 대부분의 단일 조회는 git 프로세스 하나에 10–40ms다. 이 가운데 약 8ms는 shim 비용이다.
2. commit-graph 유무가 가장 큰 변수다. 영향이 큰 것은 `--date-order`(8.5배), `-- <path>`(6배, changed-path Bloom 필터), `rev-list --count`(10배)다. 앱은 commit-graph를 쓰지 않으므로(읽기 전용), 없는 저장소에서의 경험을 PB-3b로 따로 관리한다.
3. 전체 메타데이터 적재(B10)는 commit-graph와 무관하게 약 550ms다. 출력 크기가 병목이다.
4. 설계 권고는 [performance-budget.md §4](performance-budget.md)에 있다.

### 4.3 재측정 기록

| 날짜 | git | 요약 | 기록 |
|---|---|---|---|
| 2026-11-06 | 2.54.0 (Apple Git-157) | 예산 위반 없음. 직접 실행 p50이 20% 넘게 늘어난 항목 7개로 회귀 경고 수준(원인 미확정). 추가 시나리오 S1–S6에서 index가 오래된 상태의 status가 파일 1만 개 276ms, 10만 개 5.2초 | [results/2026-11-06-apple-git-2.54.md](results/2026-11-06-apple-git-2.54.md) |

---

## 5. 회귀 감시

| 대상 | 언제 | 어디서 | 비교 기준 |
|---|---|---|---|
| PERF-08 (git 기준선) | git·Xcode 업데이트 뒤, 릴리스 전 | 메인테이너 로컬 기준 장비 | 이 문서 §4 표 |
| PERF-04 (GraphEngine) | GraphEngine을 바꾸는 PR | 로컬 + CI(참고) | XCTest baseline (`.xcbaseline`) |
| PERF-01–07 | `perf` 라벨 PR, 주간 예약 실행, 릴리스 전 | 로컬 기준 장비 (CI는 참고용) | 직전 측정 기록 |

- XCTest 성능 기준값(`.xcbaseline`)은 장비 식별자별로 저장된다. 기준 장비의 기준값만 커밋한다. CI 러너의 값은 아티팩트로만 남긴다.
- 회귀 판정은 [performance-budget.md §5](performance-budget.md)를 따른다. 예산을 넘으면 위반이고, 직전보다 p95가 20% 넘게 나빠지면 경고다.
- 측정 기록은 `docs/performance/results/<YYYY-MM-DD>-<요약>.md`로 남긴다. 장비, macOS, git 버전, 측정 표를 포함한다. `measure-git-baseline.sh` 출력을 그대로 붙이면 된다.
- CI 러너는 장비 성능과 부하가 일정하지 않다. 그래서 CI 성능 결과로는 PR을 막지 않는다. 대신 같은 러너 안에서 같은 실행의 상대 비교(예: shim 대 직접 실행)만 참고한다.

---

## 6. 앞으로 측정할 시나리오 (Phase 4)

- untracked 파일 수만 개(`node_modules` 같은) 워크트리의 status — 2만 개까지는 쟀다(2026-11-06, S4). git 시간보다 출력 크기(383KB)가 문제다
- index가 오래된 상태의 status — 쟀다(2026-11-06, S3). 앱 측정(PERF)에도 넣는다(#168)
- fetch가 도는 동안 status 새로고침이 얼마나 밀리는지(#76)
- 서브모듈이 있는 저장소
- 네트워크 원격 fetch (타임아웃 120초 경계, 진행 표시)
- 차가운 캐시 (재부팅 직후 첫 열기)
- 최소 지원 git(2.36)과 Homebrew 최신 git 비교
- 저장소 3개 이상을 등록했을 때의 앱 시작 시간

---

## 7. PERF 테스트 실행 방법 (#90)

PERF 테스트는 환경 변수를 켰을 때만 돈다. 보통의 `xcodebuild test`와 필수 CI에서는 건너뛴다(PERF-04 제외). xcodebuild에서는 변수 이름 앞에 `TEST_RUNNER_`를 붙인다.

| 변수 | 효과 |
|---|---|
| `OVERGROVE_BENCH_REPO=<dir>` | `make-bench-repo.sh` 출력 폴더. PERF-01·02·03·11·12 실행 |
| `OVERGROVE_PERF=1` | 합성 입력 테스트 PERF-05·09 실행. 예전 `OVERGROVE_BENCH_DIFF=1`도 PERF-09를 켠다 |
| `OVERGROVE_PERF_REPORT_ONLY=1` | 예산을 넘어도 실패하지 않고 표에만 적는다 (CI 러너) |
| `OVERGROVE_PERF_REPORT_DIR=<dir>` | 테스트마다 결과 표를 `<dir>/PERF-nn.md`로 쓴다 |

**로컬 (기준 장비)**

```sh
scripts/make-bench-repo.sh --commit-graph ~/tmp/overgrove-bench      # 약 30–50초, 한 번만
TEST_RUNNER_OVERGROVE_BENCH_REPO=~/tmp/overgrove-bench \
TEST_RUNNER_OVERGROVE_PERF=1 \
TEST_RUNNER_OVERGROVE_PERF_REPORT_DIR=~/tmp/perf-report \
xcodebuild test -project Overgrove.xcodeproj -scheme Overgrove -destination 'platform=macOS' \
  -only-testing:OvergroveTests/RepositoryOverviewBenchmarkTests \
  -only-testing:OvergroveTests/GraphBenchmarkTests \
  -only-testing:OvergroveTests/DetailBenchmarkTests \
  -only-testing:OvergroveTests/GraphEnginePerformanceTests \
  -only-testing:OvergroveTests/DiffViewerBenchmarkTests
```

- PB-3b를 보려면 `--commit-graph` 없이 만든 bench 폴더를 넘긴다. PERF-03이 commit-graph 유무를 보고 예산을 고른다.
- 다른 빌드·테스트가 같은 장비에서 돌면 p95가 흔들린다. 기록으로 남길 측정은 장비가 한가할 때 하고, 부하가 있었으면 기록에 적는다.
- 결과를 남길 때는 `<dir>/PERF-*.md` 표를 `docs/performance/results/<YYYY-MM-DD>-<요약>.md`에 붙인다(§5).

**CI (선택 실행)**: `.github/workflows/perf.yml`. Actions 탭에서 `perf`를 수동 실행하거나(이 저장소의 아무 브랜치), 매주 월요일 예약 실행이 main에서 돈다.
- bench 저장소를 만들고 위 테스트를 `OVERGROVE_PERF_REPORT_ONLY=1`로 돌린다.
- 표는 job summary에 붙는다.
- 필수 검사가 아니고, PR을 막지 않는다. 러너끼리는 비교하지 않고 같은 실행 안의 상대 비교만 참고한다.

