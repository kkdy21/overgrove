# 벤치마크 계획

> 상태: Accepted (Phase 2 게이트, 2026-11-05) · 관련: [performance-budget.md](performance-budget.md), [test-strategy.md](../testing/test-strategy.md), ADR-0008, ADR-0010

[성능 예산](performance-budget.md)을 어떻게 재고, 회귀를 어떻게 잡는지 정한다. 앱이 없는 지금도 쓸 수 있는 git 계층 측정 도구와, Phase 3 이후의 앱 측정 방법을 함께 다룬다.

---

## 1. 도구

| 도구 | 용도 | 시점 |
|---|---|---|
| [`scripts/make-bench-repo.sh`](../../scripts/make-bench-repo.sh) | 대형 기준 저장소 생성 (결정적) | 지금 |
| [`scripts/measure-git-baseline.sh`](../../scripts/measure-git-baseline.sh) | git 계층 비용 측정, Markdown 표 출력 | 지금 |
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

- untracked 파일 수만 개(`node_modules` 같은) 워크트리의 status
- 서브모듈이 있는 저장소
- 네트워크 원격 fetch (타임아웃 120초 경계, 진행 표시)
- 차가운 캐시 (재부팅 직후 첫 열기)
- 최소 지원 git(2.36)과 Homebrew 최신 git 비교
- 저장소 3개 이상을 등록했을 때의 앱 시작 시간
