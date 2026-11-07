# S-10 Diff 뷰어 렌더링 비용 (2026-11-07)

> 상태: 측정 기록 · 관련: #232, [performance-budget.md](../performance-budget.md) §3 PB-9(제안), [screens.md](../../design/screens.md) S-10, ADR-0008

파일 하나의 patch를 파싱하고(`PatchParser`), 화면 행을 만들고(`DiffDocument.unifiedRows`/`splitRows`), 첫 프레임을 그리는 시간이다. git 실행 시간은 포함하지 않는다(워크트리 diff는 [PB-5 표](../performance-budget.md)의 `diff --numstat`와 비슷한 수십 ms).

- 입력: 합성 patch. 20줄 hunk에 삭제·추가 반반, 줄마다 탭 1개 + 58자. 500줄(보통), 10,000줄(S-10의 큰 diff 확인 기준), 160,000줄(약 9.6MiB, 출력 상한 10MB 근처).
- 11회 실행에서 첫 회는 버렸다.
- 측정 테스트: `OvergroveTests/Performance/DiffViewerBenchmarkTests`, `TEST_RUNNER_OVERGROVE_BENCH_DIFF=1`일 때만 실행(CI 제외).

## 환경

Apple M1 8코어, git 2.50.1 (Apple Git-155), Debug 빌드 테스트 호스트. 다른 에이전트 세션들이 같은 장비에서 빌드·테스트를 함께 돌렸다.

## 결과 (p50 / p95, ms)

| 크기 | 파싱 | 통합 행 | 분할 행 | 첫 프레임(메인 스레드) |
|---|---|---|---|---|
| 500줄, 30KiB | 0.8 / 0.8 | 2.7 / 2.8 | 2.9 / 2.9 | 9.2 / 9.8 |
| 10,000줄, 613KiB | 14.1 / 14.3 | 54.3 / 54.9 | 57.0 / 58.0 | 9.0 / 9.5 |
| 160,000줄, 9.6MiB | 220.0 / 221.5 | 847.1 / 857.3 | 908.3 / 914.7 | 9.4 / 9.9 (큰 diff 확인 화면) |

## 판단

- **파싱과 행 만들기는 메인 스레드 밖에서 한다.** 파싱은 diff 로더(`LiveDiffLoader`, nonisolated)에서, 행은 뷰의 `.task`에서 분리된 작업으로 만든다. 그래서 첫 프레임은 크기와 상관없이 약 9ms다. 처음 구현은 행을 `body`에서 만들어 10MB diff에서 `Show Diff` 뒤 메인 스레드가 약 0.85초 멈췄고, 이 측정을 보고 바꿨다.
- **10,000줄까지는 열기에서 행 표시까지 약 70ms**(파싱 14 + 행 55, git 제외)로 제안 예산 PB-9 200ms 안이다.
- **큰 diff(1만 줄 초과)** 는 확인 화면을 먼저 보이고, `Show Diff` 뒤 약 0.9초 동안 진행 표시를 띄운 채 행을 만든다(UI는 멈추지 않음). 출력 상한까지 가는 diff에서만 생기는 시간이라 지금은 받아들인다. 줄이려면 행을 미리 만들지 않고 화면에 보일 hunk만 변환하는 지연 변환을 검토한다(later).
- 행은 `LazyVStack`이라 스크롤 중에는 보이는 줄만 레이아웃한다.
