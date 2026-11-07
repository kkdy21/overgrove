# 그래프 포맷에 co-author 트레일러 추가 (2026-11-07)

> 상태: 측정 기록 · 관련: #160, [performance-budget.md](../performance-budget.md) PB-3·PB-3b, [benchmark-plan.md](../benchmark-plan.md)

`ReadOnlyGitCommand.logFormat` 끝에 `%x00%(trailers:key=Co-authored-by,valueonly,unfold,separator=%x1f)`를 붙인 뒤 그래프 명령 비용을 비교했다.

## 환경

| 항목 | 값 |
|---|---|
| git | Xcode 개발자 디렉터리의 `usr/bin/git` 2.54.0 직접 실행, `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `LC_ALL=C` |
| 저장소 | `make-bench-repo.sh` 기본값(커밋 약 10만, 트레일러 없음) |
| 명령 | `log --exclude=refs/stash --all --date-order -z <format> [-n 500]` |
| 반복 | 첫 페이지 11회, 전체 3회. median, 프로세스 생성 포함, ms |
| 주의 | 같은 장비에서 다른 에이전트 세션이 함께 돌았다 |

## 결과

| 조건 | 측정 | 기존 6필드 | 트레일러 포함 7필드 | 예산 |
|---|---|---|---|---|
| commit-graph 없음 | 첫 페이지 500 | 459 | 443 | PB-3b 1.0초 |
| commit-graph 없음 | 전체 10만 | 601 | 646 | — |
| commit-graph 있음 | 첫 페이지 500 | 47 | 48 | PB-3 500ms |
| commit-graph 있음 | 전체 10만 | 587 | 719 | — |

- 첫 페이지(PB-3·PB-3b)는 차이가 측정 잡음 안이다. 예산 안이다.
- 전체를 한 번에 읽으면 45–130ms 늘어난다(7–22%). git이 커밋마다 메시지 끝의 트레일러 블록을 찾기 때문이다. 스트리밍·페이지 방식 결정(ADR-0010 후속)에서 이 값을 쓴다.
- 출력 크기는 레코드마다 1바이트(빈 필드의 NUL) 늘어난다. 트레일러가 있는 커밋은 값 길이만큼 더 늘어난다.
- 파서 쪽 추가 비용은 빈 필드 하나를 나누는 것뿐이라 따로 재지 않았다.
