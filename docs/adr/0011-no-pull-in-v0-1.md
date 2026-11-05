# ADR-0011: v0.1에서는 Pull 기능과 버튼을 빼고 fetch만 둔다

> 상태: Accepted · 날짜: 2026-11-05 · 관련: N3, N4, HANDOFF §8.2

## 맥락

HANDOFF §8.2 와이어프레임 툴바에 `[↓ Pull]` 버튼이 있다. pull은 fetch 뒤에 merge나 rebase로 **작업 트리와 브랜치를 바꾸는 쓰기 작업**이다. 충돌, 훅 실행, 인덱스 잠금이 따라온다. 조회 전용 원칙(N3, N4)과 맞지 않고, 실행 경로(hooks, 필터, merge driver)도 크게 늘어난다.

## 결정

1. v0.1.0 툴바에는 `Fetch`만 둔다. Pull 버튼은 비활성 상태로도 두지 않는다. 쓸 수 없는 버튼은 혼란만 준다.
2. `FetchCommand` 외의 원격 동기화 타입을 만들지 않는다.
3. Pull은 `later` 마일스톤 이슈로 등록한다. 다시 검토하려면 다음이 먼저 필요하다.
   - merge driver와 hooks를 다룰 보안 설계
   - 충돌 UI
   - 사용자 확인 절차

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| 비활성 Pull 버튼 유지 | 미래 기능 예고 | 혼란, 조회 앱 정체성 흐림 | UX |
| `pull --ff-only`만 허용 | 충돌이 없음 | 여전히 작업 트리를 쓰고, checkout 계열 실행 경로가 생김 | N3 취지 |

## 결과

- 쓰기 경로가 fetch(원격 추적 ref, `FETCH_HEAD`, 객체 저장소 갱신)로 한정된다.
- 사용자는 pull을 터미널이나 다른 도구에서 해야 한다. 이 앱은 그 전후 상태를 보여 주는 역할에 집중한다.

## 후속 작업

- [ ] 화면 명세 S-01 툴바에서 Pull 제거 ([design/screens.md](../design/screens.md))
- [ ] `later` 이슈: "feat: pull action with safety design"
