# ADR-0017: 디자인 토큰은 Swift 스크립트로 Asset Catalog와 Swift 상수를 생성해 커밋한다

> 상태: Accepted · 날짜: 2026-11-07 · 관련: #35, #166, ADR-0006, [ADR-0014](0014-panel-theme-and-split-layout.md), [design-tokens.md §4](../design/design-tokens.md#4-swiftui-매핑-35)

## 맥락

색, 간격, 크기, 글꼴, 움직임의 원본은 `design/tokens/tokens.json`이다. ADR-0014로 메인 창이 자체 패널 테마를 쓰게 되면서, 표면·텍스트·테두리까지 앱이 라이트·다크·고대비 값을 모두 가져야 한다. 원본을 앱으로 옮기는 방법이 없으면 JSON과 앱이 어긋난다. 외부 도구는 쓸 수 없다(ADR-0006).

## 결정

**`scripts/tokens/generate.swift`(Foundation만 사용, `swift`로 실행)가 `tokens.json`을 읽어 Asset Catalog 색 세트와 `Tokens` Swift 상수를 만든다. 결과물은 커밋하고, CI가 생성기를 다시 돌려 차이가 있으면 실패시킨다.**

- **출력**
  - `Overgrove/Resources/Assets.xcassets/Tokens/<이름>.colorset`: semantic 색마다 하나. `provides-namespace`라서 이름은 `Tokens/surfaceWindow`다.
  - `Overgrove/Resources/Assets.xcassets/AccentColor.colorset`: `semantic.color.accent`. `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`으로 앱 액센트에 등록한다.
  - `Overgrove/DesignSystem/Tokens.generated.swift`: `Tokens.Color`, `Spacing`, `Radius`, `Size`, `Font`, `Motion`, `Opacity`, `Graph`.
- **이름.** 토큰 경로를 lowerCamelCase로 바꾼다. `surface.panel-header` → `Tokens.Color.surfacePanelHeader`, `graph.lane.0` → `graphLane0`.
- **모드.** 색 세트마다 Any / Dark / High Contrast / Dark High Contrast 네 변형을 둔다. 값은 `modes.dark`, `modes["high-contrast"]`, `modes["dark-high-contrast"]`에서 읽는다. 대체 순서는 high-contrast → `$value`, dark-high-contrast → dark → `$value`이다. 별칭은 지금 풀고 있는 모드에서 푼다.
- **런타임 색.** `accent`와 그 별칭(`surface.splitter-grip-active`, `graph.head-ring`)은 `Color.accentColor`로 만든다. 그래서 사용자가 고른 시스템 액센트가 이긴다. `border.focus`는 `NSColor.keyboardFocusIndicatorColor`를 참조한다. 이 셋은 색 세트를 만들지 않는다.
- **글꼴.** 모든 typography 토큰은 `$extensions.swiftui`에 SwiftUI 텍스트 스타일을 적어야 한다. 없으면 생성기가 실패한다. 포인트 크기를 쓰는 예외는 `initials` 하나다. 고정 크기 아바타 안의 글리프라서 텍스트 스타일이 맞지 않는다.
- **결정성.** 키를 정렬해 출력하고, 숫자는 가장 짧은 형태로 쓴다. 토큰이 사라진 색 세트는 지운다. 내용이 같으면 파일을 다시 쓰지 않는다.
- **검증.**
  - CI: `colorcheck.py`(4개 모드)를 돌린 뒤 생성기를 돌리고 `git diff --exit-code`와 미추적 파일을 확인한다.
  - `TokensTests`: 생성기와 별도로 JSON을 풀어서 비교한다. 대상은 색 세트 네 변형, 번들에 컴파일된 light·dark 값, `Tokens` 상수 전부, 고대비 4.5:1 규칙이다.

## 대안

| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| 손으로 관리 | 시작이 빠름 | JSON과 앱이 어긋남, 색 세트 70여 개 × 4변형 | 단일 원본 원칙 위반 |
| Style Dictionary 등 외부 도구 | 기능 풍부 | Node 의존성 | ADR-0006 위반 |
| 빌드 단계(Run Script)에서 생성 | 커밋할 결과물이 없음 | `ENABLE_USER_SCRIPT_SANDBOXING`과 충돌, 빌드마다 실행, 리뷰에서 결과가 안 보임 | 커밋 + CI 확인이 더 단순하고 리뷰 가능 |
| Xcode 생성 심볼(`ColorResource`)로만 참조 | 오타를 컴파일러가 잡음 | 이름 변환 규칙이 Xcode 버전에 따라 바뀔 수 있음 | `Tokens` 상수 + 모든 이름을 번들에서 찾는 테스트로 같은 안전성을 얻음 |

## 결과

- 좋아지는 점
  - 토큰을 고치면 명령 하나로 앱 색과 상수가 따라온다. 어긋나면 CI가 막는다.
  - 고대비 값이 JSON에 있으므로 `colorcheck.py`가 4개 모드를 모두 검증한다.
- 나빠지는 점, 감수하는 비용
  - 생성기(약 500줄)를 유지해야 한다.
  - High Contrast 변형은 `NSAppearance(named:)`로 만들 수 없어 프로세스 안에서 확인할 수 없다. 그래서 색 세트 원본과 `assetutil --info` 결과로 확인한다.
  - `surface.wip-row`는 액센트에 알파를 섞은 고정 값이라 사용자 액센트를 따라가지 않는다.
- 다시 검토해야 하는 조건
  - DTCG가 모드를 표준화하면 `$extensions` 모드 표기를 옮긴다.
  - 토큰 수가 크게 늘어 생성 결과 리뷰가 부담스러워질 때

## 후속 작업

- [x] 생성기, 색 세트, `Tokens.generated.swift`, CI 확인, 테스트 (#35)
- [x] [design-tokens.md §2.1, §4, §5.6](../design/design-tokens.md) 갱신 (#35)
