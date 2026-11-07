# 성능 예산

> 상태: Accepted (Phase 2 게이트, 2026-11-05) · 관련: [benchmark-plan.md](benchmark-plan.md), [docs/README.md §2.8](../README.md), ADR-0008, ADR-0010, HANDOFF G9

**최근 검증**: [qa/reports/2026-11-08-performance-budget.md](../qa/reports/2026-11-08-performance-budget.md) (#98). 측정한 범위에서 PB-1–PB-9 위반이 없다. 재지 않은 항목은 그 보고서 §4에 있다.

HANDOFF G9의 "체감상 즉시"를 측정 가능한 수치로 바꾼 문서다. 각 예산에는 측정 시작점과 끝점, 데이터셋, 장비, 회귀 기준이 있다.

앱이 아직 없으므로 git 계층 비용을 먼저 쟀다 (`scripts/measure-git-baseline.sh`). 앱이 아무리 빨라도 git이 쓰는 시간보다 빠를 수는 없으므로, 이 값이 각 예산의 하한선이다. 남는 예산이 파싱, 모델 갱신, SwiftUI 렌더링에 쓸 수 있는 시간이다.

---

## 1. 공통 조건

| 항목 | 기준 |
|---|---|
| 기준 장비 | Apple Silicon M1급 (M1, M1 Pro). 실측은 M1 Pro 10코어, 32GB, macOS 26.6 |
| 기준 데이터셋 | `scripts/make-bench-repo.sh` 기본값: 커밋 100,024개(병합 2,782개), 브랜치 13개, 태그 10개, 추적 파일 10,000개, 워크트리 10개(각각 staged 5 · unstaged 15 · untracked 10), stash 5개 |
| commit-graph | 별도 표기가 없으면 **있음**(`--commit-graph`). gc를 한 번이라도 거친 실제 저장소는 대개 commit-graph가 있다 (`gc.writeCommitGraph` 기본 true). 없는 조건은 보조 예산으로 따로 둔다 |
| git | `/usr/bin/git` 2.50.1 (Apple Git-155). 앱은 shim을 거치지 않고 `xcode-select -p` 아래의 실제 실행 파일을 쓴다(§4 권고 1, `GitEnvironment.discover`). 2.54.0 (Apple Git-157) 재측정: [results/2026-11-06-apple-git-2.54.md](results/2026-11-06-apple-git-2.54.md) |
| 실행 조건 | [git-command-catalog.md §2](../architecture/git-command-catalog.md)의 공통 인자와 환경 변수를 그대로 쓴다 |
| 통계 | p95, nearest-rank, 반복 20회 이상. 첫 실행은 워밍업으로 버린다 |
| 캐시 상태 | 따뜻한 캐시(warm). 같은 측정을 두 번째부터 센다. 차가운 캐시(cold)는 참고용으로만 기록한다 |
| 허용 오차 | 같은 장비에서 반복 측정 시 ±10%를 잡음으로 본다 |

---

## 2. 예산

### PB-1 저장소 열기 → 워크트리 10개 목록과 상태 요약 표시 — **1.0초 (p95)**

- **시작**: 사용자가 사이드바에서 저장소를 선택한 시점. 앱은 이미 실행 중이다.
- **끝**: 워크트리 10개 행이 모두 그려지고, 각 행에 변경 수(✎n)와 ahead/behind가 표시된 첫 프레임.
- **포함**: `worktree list`, 워크트리별 `status --porcelain=v2 --branch`(ahead/behind는 `# branch.ab` 헤더에서 얻음), `for-each-ref`, `stash list`, 파싱, 모델 갱신, 렌더링.
- **제외**: 그래프, 이슈 패널, fetch.

| git 계층 실측 (p95) | 값 |
|---|---|
| `worktree list --porcelain -z` | 18ms |
| `status` × 10, 병렬 4 | 172ms (직접 실행 파일 기준, §4) |
| `status` × 10, 병렬 10 | 184ms |
| `for-each-ref` + `stash list` | 41ms |
| **합계 (단계별 순차 실행 가정)** | **약 240ms** |

**판단**: 현실적이다. 렌더링과 파싱에 760ms가 남는다. 목표는 그대로 1.0초로 두고, 내부 목표로 500ms를 함께 기록한다.

### PB-2 캐시된 워크트리 간 전환 — **100ms (p95)**

- **시작**: 사이드바에서 다른 워크트리를 클릭(또는 ↑/↓)한 시점.
- **끝**: 상세 패널과 WIP 행이 새 워크트리의 캐시 내용으로 바뀐 첫 프레임.
- **포함**: 메모리 캐시 조회, 뷰 갱신. 백그라운드 새로고침은 포함하지 않는다. 결과가 오면 다시 그린다.

git 계층: 해당 없음. 백그라운드 status는 35ms (p95)다.

측정(#88): 서비스 쪽 캐시 읽기(`cachedOverview` + `snapshot`)는 p95 15µs, 선택 직후 백그라운드 새로고침(probe + status)은 p95 29ms다([results/2026-11-07-pb2-cached-worktree-switch.md](results/2026-11-07-pb2-cached-worktree-switch.md)). 뷰 갱신을 포함한 첫 프레임은 워크트리 목록 화면(#65)에서 다시 잰다.

**판단**: 현실적이다. git을 기다리지 않는다는 것이 이 예산의 전제다. 전환할 때 동기적으로 git을 부르면 위반이다.

### PB-3 그래프 첫 페이지(500개) 표시 — **500ms (p95, commit-graph 있음)** / **1.0초 (p95, commit-graph 없음, 보조 예산 PB-3b 제안)**

- **시작**: 저장소 열기 직후 또는 그래프 탭 진입 시점.
- **끝**: 그래프 영역에 커밋 500개 중 화면에 보이는 행과 레인이 그려진 첫 프레임.
- **포함**: `log --exclude=refs/stash --all --date-order -z`, 파싱, 레인 계산(GraphEngine), 렌더링.
- 측정(#68): 첫 페이지 git+파싱 p95 약 50ms(commit-graph 있음), 약 450ms(없음). 페이지당 레이아웃은 5ms 이하다. 페이지 방식 근거는 [results/2026-11-07-pb3-graph-paging.md](results/2026-11-07-pb3-graph-paging.md), 결정은 #89에서 한다.

| git 계층 실측 (p95) | commit-graph 있음 | commit-graph 없음 |
|---|---|---|
| `log … --date-order -n 500` | **49ms** | **416ms** |
| 전체를 스트리밍할 때 첫 500개(약 76KB)가 나오기까지 | 41ms | 408ms |
| `log … --date-order --skip=50000 -n 500` (페이지 이동) | 50ms | 419ms |
| `log` 기본 순서 `-n 500` (참고: 위상 정렬 보장 없음) | 25ms | 24ms |

**판단**:
- commit-graph가 있으면 여유가 크다.
- 없으면 `--date-order`가 전체 이력을 다 걸어야 첫 줄을 내보낸다. 그래서 git만으로 400ms가 넘고, 파싱과 렌더링을 더하면 500ms를 넘길 가능성이 높다.

**제안**:
1. PB-3는 commit-graph가 있는 조건으로 정의한다. 없는 조건은 보조 예산 **PB-3b 1.0초**로 둔다.
2. commit-graph가 없을 때 `--skip`으로 페이지를 넘기면 페이지마다 약 400ms가 다시 든다. 그래서 **프로세스 하나로 전체 메타데이터를 스트리밍**하고, 첫 500개가 파싱되는 즉시 그린다. 전체 10만 개 적재는 약 560ms, 출력은 15MB다. ADR-0010 검토 대상이다.
3. 앱은 commit-graph를 **쓰지 않는다** (읽기 전용 원칙). 대신 S-05 워크트리 상세나 상태바에 "commit-graph 없음: `git commit-graph write --reachable`을 실행하면 그래프가 빨라집니다" 같은 안내를 둘지 검토한다 (Phase 2 결정 사항).
4. WIP 행과 그래프 골격은 git 응답을 기다리지 않고 먼저 그린다.

### PB-4 그래프 스크롤 — **프레임 드롭 없음 (60fps)**

- **측정**: 10만 커밋을 모두 적재한 상태에서 그래프를 위에서 아래까지 빠르게 스크롤한다 (XCUITest swipe + `XCTOSSignpostMetric.scrollDecelerationMetric`).
- **기준**: hitch time ratio 5ms/s 미만 (Apple 기준 "좋음"). 끊기는 프레임이 눈에 보이지 않아야 한다.
- **전제**: 스크롤 중에는 git을 부르지 않는다. 행 렌더링은 지연 생성(lazy)하고, 레인 데이터는 미리 계산해 둔다.

git 계층: 해당 없음.

**판단**: 측정 가능하도록 지표를 hitch ratio로 구체화했다. 120Hz 디스플레이에서는 같은 hitch ratio 기준을 쓴다.

### PB-5 파일 1만 개 워크트리의 status 새로고침 — **300ms (p95)**

- **시작**: ⌘R 또는 자동 새로고침 트리거.
- **끝**: 상세 패널의 Staged/Unstaged/Untracked/Conflicted 목록이 갱신된 첫 프레임.

| git 계층 실측 (p95) | `/usr/bin/git` | 직접 실행 파일 |
|---|---|---|
| `status --porcelain=v2 -z --branch --untracked-files=all` (파일 1만 개, 변경 30개) | 37ms | 27ms |
| `diff --numstat` (워크트리 대 인덱스) | 29ms | 20ms |

**판단**: 여유가 크다 (git 약 35ms). 목표는 300ms로 두되, 회귀 감시는 git 계층 기준 +50%(약 55ms)로 더 엄격하게 둔다. untracked 파일이 수만 개인 저장소(`node_modules` 같은 경우)는 별도 시나리오로 Phase 4에서 측정한다. HANDOFF §9의 `--untracked-files=all` 주의 사항에 해당한다.

**untracked 모드와 표시 상한 (확정, #91, 2026-11-08)**: `--untracked-files=all`을 유지하고, WIP 상세의 untracked 표시 상한은 **5,000개**로 확정한다.
- 근거: 추적 파일 1만 개 워크트리의 선택 새로고침 p95 33.6ms(#98 보고서). untracked 2만 개에서도 git 시간은 47ms다(2026-11-06 측정). 출력(약 383KB)은 stdout 상한(10MB)보다 훨씬 작다. StatusParser는 한 번 훑는 선형 파서이고 10만 레코드를 Debug 빌드에서 1초 안에 처리한다(#51). 목록은 lazy로 그리고 5,000개에서 끊으므로(#66) 렌더링 비용에도 상한이 있다.
- `normal`(디렉터리 단위)로 바꾸지 않는 이유: 에이전트가 새로 만든 파일을 파일 단위로 보여 주는 것이 S-02의 핵심이다. `node_modules`처럼 큰 무시 대상은 `.gitignore`로 빠진다.
- 재검토 조건: untracked 수만 개 저장소에서 파싱·모델 단계가 PB-5를 넘는다는 측정이 나오면 `normal` 전환 또는 상한 축소를 다시 본다.

**index가 오래된 상태 (2026-11-06 측정)**: 파일 내용은 그대로이고 mtime만 바뀐 파일이 많으면, 앱은 index를 쓰지 않으므로(`--no-optional-locks`) status가 매번 그 파일들을 다시 해시한다. 파일 1만 개에서 p95 328ms로 이 예산을 넘고, 10만 개에서는 5.8초다. 터미널이나 에이전트가 git을 한 번 실행하면 원래 속도로 돌아온다. 앱은 index를 갱신하지 않는다(쓰기이고, 에이전트의 git 작업과 `index.lock`이 부딪칠 수 있다). 대신 느린 status를 감지해 안내한다(#168). 이 상태는 PB-5 판정에서 빼고 PERF 시나리오로 따로 기록한다([results/2026-11-06-apple-git-2.54.md](results/2026-11-06-apple-git-2.54.md) S3).

### PB-6 커밋 10만 개 메타데이터 적재 시 메모리 — **300MB 이하**

- **측정**: 저장소 열기 → 그래프 전체 적재 → `XCTMemoryMetric` 최대 물리 메모리.
- **참고**: git 출력 원문은 15.1MB다 (`%H %P %an %ae %at %s`, NUL 구분). OID를 20바이트 바이너리로, 작성자를 문자열 intern으로 저장하면 커밋당 200바이트 안팎이 된다. 그러면 모델은 수십 MB 수준이다.

**스트리밍 그래프(#254)**: commit-graph 없는 저장소는 그래프 커밋을 스트림이 들고 있는다. 저장소당 최대 10만 개, 저장소 2개까지라 PB-6 안이다.

**판단**: 현실적이다. 그대로 둔다.

---

## 3. 추가 제안 예산

docs/README.md §2.8에는 없는 항목이다. 승인되면 공통 규약에 추가한다.

| 제안 ID | 시나리오 | 목표 (p95) | 근거 (git 계층 p95) |
|---|---|---|---|
| PB-3b | commit-graph 없는 저장소의 그래프 첫 페이지 | 1.0초 | `--date-order -n 500` 416ms. #254 이후 한 프로세스 스트림: 앱 경로 첫 페이지 p50 474ms, 다음 페이지 0.2ms ([결과](results/2026-11-08-pb3b-graph-streaming.md)) |
| PB-7 | 파일 이력(S-09) 첫 100개 표시 | 1.0초 | `log --follow -n 100` 392ms (graph 있음), 675ms (없음). follow 없이는 25ms / 153ms |
| PB-8 | 커밋·stash 상세(S-03, S-04) 파일 목록 표시 | 200ms | `show --numstat` 17ms, `stash show --numstat` 19ms |
| PB-9 | Diff 뷰어(S-10)에서 파일 하나의 diff 표시(1만 줄 이하) | 200ms, 메인 스레드 첫 프레임 16ms | 1만 줄: 파싱 14ms + 행 55ms(메인 스레드 밖), 첫 프레임 9ms ([결과](results/2026-11-07-s10-diff-viewer.md)) |
| PB-10 | 자동 새로고침(#119) 중 파일 쓰기 폭주 | 새로고침 요청 ≤ 경과 시간/2초 + 1, 그동안 git CPU ≤ 한 코어의 10% | 파일 6,000개를 8초 동안: 요청 3회(상한 9), status 3회, git CPU 0.7% (PERF-10, [결과](results/2026-11-07-perf10-auto-refresh-storm.md)) |

---

## 4. 예산을 지키기 위한 설계 권고 (실측 근거)

1. **`/usr/bin/git`의 xcrun shim 비용을 없앤다.**
   - `/usr/bin/git`은 실제 git을 찾아 실행하는 shim이다. 호출마다 약 8ms가 더 든다 (`rev-parse HEAD` p50 15ms 대 7ms).
   - PB-1 한 번에 git을 15–25회 부르므로 120–200ms가 shim에 쓰인다. 예: ahead/behind 10회 순차 169ms → 89ms.
   - 권고: 앱 시작 시 실제 실행 파일 경로를 한 번 확정해 캐시한다. 예: `xcrun --find git` → `/Library/Developer/CommandLineTools/usr/bin/git`. 그 뒤로는 그 경로를 직접 실행한다.
   - 경로 검증 규칙(절대 경로, 소유자, 실행 권한)은 ADR-0008에서 정한다.
2. **status 병렬도는 min(코어, 8)로 둔다**(#87에서 4에서 바꿈). 워크트리 10개 status를 병렬도별로 쟀다 (p50).
   - 1: 269ms, 2: 203ms, 4: 163ms, 6: 151ms, 10: 128ms (p95 167ms)
   - 4를 넘으면 이득이 작고 디스크 경합만 커진다. 기본값은 4로 하고, 설정이나 코어 수에 따라 바꿀 수 있게 한다.
   - → #87: `RepositoryService`로 PB-1 묶음 전체(worktree list + 워크트리별 확인·status 10개 + refs + stash)를 재면, 기본값 8에서 p95 약 135–150ms이고 한도 4보다 p50이 약 18% 빠르다(M1 8코어, [results/2026-11-07-pb1-parallel-worktree-queries.md](results/2026-11-07-pb1-parallel-worktree-queries.md)). 기본값을 min(코어, 8), 최소 2로 정했다. 코어가 적은 장비에서는 코어 수를 넘지 않는다. 한도 8 이상에서 보이던 1초 지연은 `ProcessRunner`의 종료 확인 수정으로 없앴다(같은 문서).
3. **저장소를 열 때 `rev-list --count --all`을 부르지 않는다.** commit-graph가 없으면 394ms가 든다. 총 커밋 수가 필요하면 그래프 스트리밍이 끝난 뒤 센다.
4. **ahead/behind는 status 헤더에서 얻는다.** `--branch`의 `# branch.ab`를 쓰면 `rev-list --left-right --count`를 따로 부르지 않아도 된다. 워크트리 10개 기준으로 89–169ms를 아낀다.
5. **그래프는 스트리밍 한 번으로 받는다** (PB-3 제안 2).
6. **파일 이력은 follow 없는 조회를 먼저 보여준다.** `--follow`는 비싸다 (392–675ms). 먼저 `log -- <path>` 결과(25–153ms)를 보여주고, 이름 변경 이전 이력은 follow 결과가 오면 덧붙이는 방식을 S-09 설계에서 검토한다.
7. **로컬 브랜치 ahead/behind는 `for-each-ref` 한 번으로 얻는다** (2026-11-06 측정). `%(upstream:track,nobracket)`을 붙여도 1ms 안팎만 늘어난다. 브랜치마다 `rev-list`를 실행하면 13개에 95ms가 들고 그동안 동시 실행 슬롯을 차지한다(#54).
8. **fetch는 조회와 다른 동시 실행 한도를 쓴다.** fetch는 최대 120초 동안 슬롯을 잡을 수 있다. 조회와 같은 한도를 쓰면 원격이 여러 개이거나 자동 fetch가 겹칠 때 status 새로고침이 줄을 선다. → 적용됨(#76): 조회 한도(#87부터 min(코어, 8))와 별도로 fetch는 앱 전체 2개(`GitClient.defaultFetchConcurrency`)이고, 저장소당 하나씩 실행한다. fetch 진행 중에도 조회가 바로 실행되는지는 `GitFetchTests.testQueriesDoNotWaitForAFetch`가 확인한다.
9. **자동 새로고침을 넣는다면 재실행 간격에 상한을 둔다.** 창이 화면에 보일 때만 감시하고, 워크트리별로 디바운스하고, 워크트리별로 한 번에 하나만 실행하며, 마지막 소요 시간에 비례해 간격을 늘린다(예: max(2초, 소요 시간 × 10)). index가 오래된 10만 개 저장소(5.2초)에서도 한 코어의 약 10%로 묶인다(#163).

---

## 5. 회귀 기준

- **위반**: 어떤 PB의 p95가 목표를 넘으면 `type:bug` + `priority:p1` 이슈를 만든다. 릴리스 체크리스트에서 막힌다.
- **회귀 경고**: 위반이 아니더라도 같은 장비의 직전 기준값보다 p95가 20% 넘게 나빠지면 PR 코멘트로 경고한다. 원인을 설명하거나 고친 뒤 머지한다.
- **기준값 갱신**: 의도적인 변경(기능 추가로 예산을 더 쓰게 된 경우)은 PR 본문에 근거를 적고 [benchmark-plan.md](benchmark-plan.md)의 기준값 표를 갱신한다.
- git 버전이 바뀌면 git 계층 기준값을 다시 잰다. Apple Git은 Xcode·CLT 업데이트에 따라 바뀐다.
