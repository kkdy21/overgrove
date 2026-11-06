# 디자인 토큰 (Design Tokens)

> 상태: Accepted (Phase 2 게이트 2026-11-05, #166 패널 테마로 개정 2026-11-06) · 관련: [`design/tokens/tokens.json`](../../design/tokens/tokens.json), [art-direction.md](art-direction.md), [screens.md](screens.md), [interaction.md §6](interaction.md#6-접근성), [iconography.md](iconography.md), ADR-0006, ADR-0010, [ADR-0014](../adr/0014-panel-theme-and-split-layout.md)

색, 간격, 크기, 글꼴, 움직임의 **단일 원본은 [`design/tokens/tokens.json`](../../design/tokens/tokens.json)이다.** 이 문서는 그 구조와 규칙, 검증 결과, SwiftUI로 옮기는 계획을 설명한다. 값이 서로 다르면 JSON이 맞고 이 문서를 고친다. 값을 어떻게 조합해 화면을 만드는지는 [art-direction.md](art-direction.md)에 있다.

---

## 1. 원칙

1. **메인 창은 자체 패널 테마(Slate)를 쓴다** ([ADR-0014](../adr/0014-panel-theme-and-split-layout.md)). 표면, 텍스트, 테두리, 선택은 앱 토큰이 라이트·다크 값을 모두 정한다. 메뉴, 시트, 팝오버, 설정 창 같은 네이티브 컨트롤은 시스템 색을 그대로 쓴다.
2. **앱 고유 색 묶음은 여섯 개다.**
   - 표면·텍스트(slate)
   - 액센트(forest.400 / 700)
   - 상태(status)
   - 그래프 레인(graph.lane)
   - diff
   - 작성자 아바타(avatar)

   새 색이 필요하면 이 묶음 안에서 해결할 수 있는지 먼저 본다.
3. **액센트는 브랜드 초록 하나다.** 앱 아이콘의 숲색에서 가져왔다. 앱의 AccentColor로 등록하므로, 사용자가 시스템 액센트 색을 직접 골랐으면 macOS가 그 색으로 바꾼다. 액센트는 상태나 목록 선택을 나타내지 않는다.
4. **색은 의미를 혼자 지지 않는다.** 모든 상태 색은 SF Symbol과 텍스트를 함께 쓴다 ([iconography.md §5](iconography.md#5-상태-심볼-매핑), [interaction.md §6.2](interaction.md#62-색에만-의존하지-않는다)).
5. **다른 제품의 팔레트를 쓰지 않는다.** GitKraken도 포함한다. 레인 팔레트는 OKLCH에서 직접 만들고 아래 §5 방식으로 검증했다([art-direction.md §4.3](art-direction.md#43-레인-팔레트)).
6. **검증은 저장소 안에서 재현한다.** `design/mockups/generator/colorcheck.py`(표준 라이브러리만 사용)가 JSON을 읽어 §5의 기준을 다시 계산한다.

---

## 2. 구조

[W3C Design Tokens Community Group](https://tr.designtokens.org/format/) 형식을 따른다.

```
primitive/          원시 값. 의미 없음. 앱 코드에서 직접 참조 금지
  color.forest.*            브랜드 그린. 400/700은 UI 액센트, 나머지는 아이콘·README 마크
  color.slate.*             차가운 무채색 단계 (표면, 테두리, 텍스트 공용)
  color.status.*            상태 색 단계 (green-600, amber-400 …)
  color.lane.*              레인 색상군의 light/dark 단계
  color.diff.*              diff 배경 단계
  color.avatar.*            작성자 이니셜 아바타 채움
  color.system-fallback.*   목업에 그리는 창 버튼 근삿값
semantic/           역할. 앱 코드가 참조하는 유일한 층
  color.surface.*  color.text.*  color.border.*  color.accent
  color.status.*   color.on-status.*  color.graph.*  color.diff.*  color.avatar.*
  spacing.*  radius.*  typography.*  size.*  motion.*  opacity.*
```

### 2.1 라이트·다크 모드

DTCG 형식에는 아직 모드 개념이 없다. 그래서 아래처럼 표기한다.

- `$value`는 **light 모드** 값이다.
- dark 값은 `$extensions["io.github.kkdy21.overgrove"].modes.dark`에 둔다.
- 런타임에 시스템이 바꾸는 토큰은 같은 확장에 `appkit` 키로 대응 API를 적는다(예: `accent` → AccentColor, `border.focus` → 키보드 포커스 색).

```json
"staged": {
  "$value": "{primitive.color.status.green-600}",
  "$extensions": { "io.github.kkdy21.overgrove": { "modes": { "dark": "{primitive.color.status.green-400}" } } }
}
```

### 2.2 명명 규칙

| 규칙 | 예 |
|---|---|
| 키는 kebab-case | `selection-inactive`, `row-graph` |
| primitive는 `색상군-단계`. 단계가 클수록 어둡다 | `green-600`, `slate.850` |
| semantic은 역할 이름. 색상 이름을 쓰지 않는다 | `status.conflicted` (O), `status.red` (X) |
| semantic 색은 원칙적으로 별칭(`{…}`)만 쓴다. 예외는 알파를 섞어 다른 표면 위에 겹치는 `surface.hover`, `surface.control`(다크), `surface.wip-row`, `surface.scrollbar-thumb`와 `surface.selection` | |
| 그래프 레인은 숫자 인덱스 | `graph.lane.0` ~ `graph.lane.7` |
| 앱 코드는 semantic만 참조한다 | `Tokens.Color.statusStaged` (생성 이름은 §4) |

---

## 3. 토큰 요약

### 3.1 표면, 텍스트, 테두리, 액센트

| 토큰 | Light | Dark | 쓰임 |
|---|---|---|---|
| `surface.window` | `#e3e6ec` | `#0e1116` | 툴바, 패널 사이 홈, 상태바 |
| `surface.canvas` | `#ffffff` | `#14181e` | 그래프·diff 본문 |
| `surface.panel` | `#f9fafc` | `#191d24` | 사이드바·상세 본문 |
| `surface.panel-header` | `#f3f5f9` | `#1d2229` | 패널 머리, 열 머리, 하단 고정 영역 |
| `surface.raised` | `#eef0f4` | `#21252e` | 패널 안의 카드 |
| `surface.selection` | `#dee7f4` | `#252f3c` | 사이드바·상세 목록의 선택 행 |
| `surface.selection-inactive` | `#eef0f4` | `#21252e` | 포커스가 없는 패널의 선택 행 |
| `surface.hover` | 검정 4% | 흰색 4.3% | 포인터 아래 행 |
| `surface.control` | `#ffffff` + 테두리 | 흰색 6% | 칩, 세그먼트, 필드 |
| `surface.wip-row` | 액센트 7% | 액센트 9% | 그래프 WIP 행 |
| `surface.splitter-grip` | `#666c78` | `#666c78` | 분할선 손잡이(홈 대비 4.2 / 3.6) |
| `surface.splitter-grip-active` | 액센트 | 액센트 | 손잡이 hover·drag |
| `surface.scrollbar-thumb` | 검정 24% | 흰색 20% | 오버레이 스크롤바 |
| `text.primary` | `#191d24` | `#e7eaef` | 제목, 파일 이름, 커밋 제목 |
| `text.secondary` | `#4a505b` | `#b0b6c0` | 작성자, 경로 앞부분, 개수 |
| `text.tertiary` | `#666c78` | `#888e99` | SHA, 시각, 열 머리. 선택 행과 컨트롤 위에서는 `text.secondary`로 바꾼다 |
| `text.quaternary` | `#9399a2` | `#5e636e` | 자리 표시 문구, 비활성 |
| `text.on-accent` | `#ffffff` | `#0e1116` | 액센트 채움 위 |
| `border.panel` | `#d5d9e1` | `#2b303a` | 패널 테두리 |
| `border.separator` | `#e3e6ec` | `#21252e` | 패널 안 구분선 |
| `border.strong` | `#b0b6c0` | `#3d434c` | 컨트롤 테두리, Increase Contrast의 패널 테두리 |
| `accent` | `#0e764a` | `#43d59a` | 포커스 링, HEAD 링, 고른 칩, 주 버튼, 활성 손잡이, 토글 |

`primitive.color.system-fallback.window-close` / `window-minimize` / `window-zoom`은 시스템이 그리는 창 버튼을 목업에 그리기 위한 값이다. 앱 코드는 참조하지 않는다.

### 3.2 상태 색

| 토큰 | 의미 | Light | Dark | 함께 쓰는 심볼 |
|---|---|---|---|---|
| `status.staged` | 스테이징됨 | `#267d30` | `#68d36f` | `checkmark.circle.fill` |
| `status.unstaged` | 스테이징 안 된 변경 | `#a95f0e` | `#fcb442` | `pencil` |
| `status.untracked` | 추적 안 함 | `#818690` | `#878c96` | `questionmark.circle` |
| `status.conflicted` | 충돌 | `#c41f5f` | `#f3597c` | `exclamationmark.triangle.fill` |
| `status.ahead` | upstream보다 앞섬 | `#1f68bc` | `#6fb2fc` | `arrow.up` |
| `status.behind` | upstream보다 뒤처짐 | `#1f68bc` | `#6fb2fc` | `arrow.down` |
| `status.locked` | 잠긴 워크트리 | `#818690` | `#878c96` | `lock.fill` |
| `status.prunable` | 디렉터리가 사라진 워크트리 | `#a95f0e` | `#fcb442` | `questionmark.folder` |
| `status.ok` / `warning` / `error` | 점검·보안 상태, 명령 실패 | staged / unstaged / conflicted와 같은 단계 | | `checkmark.shield` 등 |

**같은 색을 일부러 공유하는 쌍.** 아래 쌍은 같은 맥락에 함께 나오지 않거나, 색이 아닌 수단이 이미 의미를 전달한다.

- `ahead` = `behind`: 화살표 방향이 의미를 전달한다. 색은 "upstream과 다르다"만 알린다.
- `untracked` = `locked`: 파일 행과 워크트리 행이라는 서로 다른 맥락에 나온다.
- `unstaged` = `prunable` = `warning`: 마찬가지로 맥락이 다르다. 워크트리 행의 변경 수는 색을 쓰지 않는다.

충돌 색은 빨강이 아니라 진홍(crimson)이다. 빨강을 쓰면 light 모드에서 주황 `unstaged`와 정상 시각으로도 구분하기 어렵다(§5.2).

**텍스트로 쓸 때.** `staged`, `conflicted`, `ahead`는 `+n` `−m` `↑n`처럼 글자로도 쓴다(패널·카드 위 4.5:1 이상). `unstaged`와 `untracked`는 심볼에만 쓴다. light의 amber는 카드 위 4.25라 글자에 쓰지 않는다(예: 상태바의 `1 prunable` 글자는 `text.secondary`, 심볼만 amber).

**파일 종류 배지.** A/M/D/R/U/? 배지는 16pt 둥근 사각형을 상태 색으로 채우고, 글자는 `on-status.*`(흰색 또는 `slate.950` 중 대비가 큰 쪽, 모두 4.5:1 이상)로 쓴다.

### 3.3 그래프 레인

| 인덱스 | 색상군 | Light | Dark | `on-lane` (Light / Dark) |
|---|---|---|---|---|
| 0 | azure | `#0e71b0` | `#43acfc` | 흰색 / slate.950 |
| 1 | jade | `#15945e` | `#25df90` | slate.950 / slate.950 |
| 2 | violet | `#7d2fc8` | `#b074fb` | 흰색 / slate.950 |
| 3 | coral | `#d7152c` | `#fc6764` | 흰색 / slate.950 |
| 4 | aqua | `#148b90` | `#27dee6` | slate.950 / slate.950 |
| 5 | amber | `#bf7012` | `#fda858` | slate.950 / slate.950 |
| 6 | magenta | `#bf1e94` | `#f75cc7` | 흰색 / slate.950 |
| 7 | yellow | `#a59316` | `#f7dc27` | slate.950 / slate.950 |

- **순서가 안전장치다.** 이웃한 레인은 항상 연속한 인덱스를 받는다. 8개를 넘으면 7 다음에 0이 온다. 그래서 이웃 쌍 검증에 **7↔0 wrap 쌍**까지 넣었다(§5.1). 순서는 이웃이 색상환에서 멀리 떨어지도록 골랐다.
- 레인 색 인덱스는 레인이 생길 때 `열 인덱스 mod 8`로 정하고, 스크롤해도 바뀌지 않는다. 색은 브랜치를 따라가고 화면상의 순위를 따라가지 않는다. 알고리즘은 ADR-0010과 [architecture/overview.md](../architecture/overview.md)에 있다.
- 0번(azure)은 보통 기본 브랜치의 레인이다. 액센트(초록)와 겹치지 않게 했다.
- `graph.on-lane.*`은 레인 색으로 채운 알약(포커스 워크트리의 브랜치) 위의 글자색이다.
- 그 밖의 그래프 토큰:
  - `graph.node-ring`: 노드 둘레 캔버스 색 후광 2px
  - `graph.head-ring`: 포커스 HEAD의 액센트 링
  - `graph.wip-node`: WIP 점선 노드. 레인 색을 쓰지 않는다
  - `graph.ref-pill-local-fill-opacity` 0.2, `graph.ref-pill-border-opacity` 0.75, `graph.ref-connector-opacity` 0.55: 알약과 연결선
  - `graph.selection-opacity` 0.16: 선택 행의 레인 색 틴트

  그리는 규칙은 [art-direction.md §5](art-direction.md#5-그래프)에 있다.

### 3.4 diff

| 토큰 | Light | Dark |
|---|---|---|
| `diff.added-bg` | `#e9f2ea` | `#1f3029` |
| `diff.removed-bg` | `#f9e9ef` | `#31202a` |
| `diff.added-word-bg` | `#cbe0cd` | `#2d5036` |
| `diff.removed-word-bg` | `#f1c9d9` | `#572b3a` |
| `diff.hunk-header-bg` | `#edf3fa` | `#1f2a39` |
| `diff.gutter-added` / `gutter-removed` | `status.staged` / `status.conflicted` 별칭 | |

배경은 상태 색을 캔버스에 섞은 값이다(줄 10% / 13%, 단어 24% / 30%, hunk 머리 8% / 12%, light / dark).

### 3.5 작성자 아바타 (#159)

네트워크 아바타(Gravatar, GitHub 프로필 사진)는 쓰지 않는다. 앱이 외부로 요청을 보내지 않고, 작성자 이메일을 제3자에게 넘기지 않기 위해서다. 대신 이름 이니셜(최대 2자)을 색 원 위에 쓴다.

| 인덱스 | 색상군 | 값 (light = dark) | 흰 이니셜 대비 |
|---|---|---|---|
| 0 | green | `#1d7a4a` | 5.34 |
| 1 | blue | `#2f67c8` | 5.39 |
| 2 | red | `#c62f3e` | 5.42 |
| 3 | violet | `#7048c8` | 6.09 |
| 4 | orange | `#b04f00` | 5.30 |
| 5 | teal | `#00778f` | 5.20 |
| 6 | gold | `#8a6a00` | 5.07 |
| 7 | magenta | `#a8389a` | 5.68 |

- **결정적 색.** 인덱스 = 작성자 이메일을 앞뒤 공백 제거·소문자화한 뒤 FNV-1a 32비트 해시 mod 8. Swift의 `hashValue`는 실행마다 바뀌므로 쓰지 않는다. 같은 사람은 어느 저장소, 어느 창에서나 같은 색이다.
- **light와 dark에서 같은 값.** 테마를 바꿔도 사람의 색이 바뀌지 않게 했다. 이니셜은 `avatar.initials`(흰색).
- **그래프 노드가 아바타다(#166).** 커밋 노드는 지름 17 아바타를 레인 색 링(2.5)으로 감싼 모양이다. 아바타 색은 사람을, 링 색은 브랜치를 나타낸다. 원 경계는 링이 맡으므로 다크 캔버스 위 아바타 경계 대비(2.9~3.5)는 문제 되지 않는다.
- **색은 보조 단서다.** 아바타 옆에는 항상 이름이 있거나(그래프 Author 열, 커밋 상세, 작성자 필터 칩) 툴팁과 VoiceOver 라벨에 이름이 있다(그래프 노드, 사이드바 원격 브랜치). 8색을 모두 구분해야 의미가 통하는 화면은 만들지 않는다(§5.4).
- AI 공동 작성자(`Co-Authored-By:` 트레일러로 판별)는 이니셜 아바타 대신 `text.tertiary` 테두리 원 + `sparkles` 심볼로 그린다. 사람처럼 보이게 하지 않는다.

### 3.6 간격·모서리·크기·글꼴·움직임

| 묶음 | 값 |
|---|---|
| `spacing` | xxs 2 · xs 4 · sm 8 · md 12 · lg 16 · xl 24 · xxl 32 (px) |
| `radius` | sm 4 · md 6 (버튼, 필드) · lg 10 (패널, popover) · pill. 카드 8과 알약 5는 [art-direction.md §9](art-direction.md#9-모양-간격-움직임) |
| `size` | 행: 사이드바 28, 워크트리 46, 그래프 30(고정, 가상화 전제), 파일 26. 그래프: 레인 간격 20, 노드 22(병합 10, HEAD 링 30), 간선 3, 노드 링 2.5, 알약 높이 18·최대 폭 150. 패널: 홈 8, 머리 40, 열 머리 28, 손잡이 4×28, 사이드바 220/256/420, 상세 300/344/560, 그래프 최소 480. 열: Refs 172(96~280), Author 108, Date 52, SHA 72. 창 최소 1040×600. 최소 클릭 영역 20 |
| `typography` | macOS 텍스트 스타일에 대응한다. large-title 26 bold(S-07 제목 전용), body 13, headline 13 bold, title(상세 제목) 15 semibold, callout 12, section-header 11 bold(대문자, 자간 0.06em), column-header 11 medium(Title Case), pill 11 medium, initials 8.5 bold, caption 10, mono 12 (SF Mono), mono-small 11. **앱 코드는 포인트 크기가 아니라 SwiftUI 텍스트 스타일을 쓴다** |
| `motion` | fast 120ms · standard 200ms · slow 350ms · easing `cubic-bezier(0.2, 0, 0, 1)`. Reduce Motion이면 크로스페이드나 애니메이션 없음. 분할선 드래그는 애니메이션 없이 포인터를 따른다 |
| `opacity` | disabled 0.4 · stale 0.6 (새로고침 실패 후 이전 데이터) |

---

## 4. SwiftUI 매핑 계획 (Phase 3 결정 사항)

외부 도구 0개 원칙(ADR-0006) 아래에서 JSON을 앱으로 옮기는 방법을 Phase 3 첫 UI 이슈(#35)에서 확정한다. 확정되면 ADR로 남긴다.

| 선택지 | 장점 | 단점 |
|---|---|---|
| **A. Swift 생성 스크립트 (권장)** — `scripts/tokens/generate.swift`(툴체인만 사용)가 JSON을 읽어 (1) `Overgrove/Resources/Assets.xcassets/Tokens/*.colorset`과 (2) `Overgrove/DesignSystem/Tokens.generated.swift`를 만든다. 결과물은 커밋한다 | 원본이 하나다. 색 세트에 light/dark/High Contrast 변형을 담을 수 있다. 외부 도구가 필요 없다 | 생성기를 유지해야 한다 |
| B. 손으로 관리 | 시작이 가장 빠르다 | JSON과 앱이 어긋나기 쉽다 |
| C. Style Dictionary 같은 외부 도구 | 기능이 풍부하다 | Node 의존성이 생긴다. ADR-0006 위반 |

권장안 A의 세부:

- 앱 고유 색은 모두 색 세트로 만든다. 표면, 텍스트, 테두리, 상태, 레인, diff, 아바타가 여기에 든다. 색 세트마다 Any / Dark / High Contrast / Dark High Contrast 네 변형을 둔다.
  - High Contrast 변형 규칙(Phase 3에서 값 확정, 배경 대비 4.5:1 이상):
    - `border.panel` → `border.strong`
    - `text.tertiary` → `text.secondary`
    - 레인·상태는 다크에서 더 밝게, 라이트에서 더 어둡게
- `accent`는 Asset Catalog의 `AccentColor`로 만든다. `border.focus`는 시스템 키보드 포커스 색을 참조하는 코드를 생성한다.
- 알파가 섞인 토큰(`surface.hover` 등)은 색 세트에 알파 그대로 둔다.
- 간격, 크기, 모서리, 움직임은 `enum Tokens { enum Spacing { static let sm: CGFloat = 8 } … }` 형태로 만든다. 글꼴은 `Font.body` 같은 텍스트 스타일 참조로 만든다.
- 어긋남 방지: CI에서 생성기를 다시 돌린 뒤 `git diff --exit-code`로 결과물이 최신인지 확인한다. 대비 검증(`colorcheck.py`와 같은 규칙)을 Swift 테스트로 옮길지는 [testing/test-strategy.md](../testing/test-strategy.md)와 맞춘다.

---

## 5. 검증 결과

모든 수치는 2026-11-06에 `design/mockups/generator/colorcheck.py`로 다시 계산했다.

- **측정 방식**
  - 대비: WCAG 2 대비율. 텍스트 4.5:1, 그래픽(레인, 상태 심볼, 포커스 링) 3:1
  - ΔE: OKLab 유클리드 거리 ×100
  - 색각 이상: Machado–Oliveira–Fernandes 2009, severity 1.0
- **표면**: §3.1의 canvas, panel, panel-header, raised, selection

### 5.0 텍스트

| 텍스트 | Light canvas / panel / header / raised / selection | Dark canvas / panel / header / raised / selection |
|---|---|---|
| primary | 16.90 / 16.18 / 15.48 / 14.81 / 13.55 | 14.77 / 14.01 / 13.26 / 12.72 / 11.23 |
| secondary | 8.11 / 7.76 / 7.43 / 7.11 / 6.50 | 8.73 / 8.29 / 7.84 / 7.52 / 6.64 |
| tertiary | 5.27 / 5.05 / 4.83 / 4.62 / *4.23* | 5.41 / 5.13 / 4.86 / 4.66 / *4.11* |
| quaternary | 2.87 ~ 2.30 (자리 표시 전용) | 2.96 ~ 2.25 (자리 표시 전용) |

- tertiary는 선택 행에서 4.5:1에 못 미친다. 그래서 선택 행에서는 secondary로 바꾼다. 그래프의 레인 틴트 선택 행도 같다(최저 4.04 / 3.68).
- 다크 `surface.control`(패널 위 흰색 6% = `#272a31`)에서 tertiary는 4.36이다. 그래서 컨트롤 안의 개수·단축키 표시는 secondary로 쓴다.

### 5.1 그래프 레인 팔레트

| 검사 | 기준 | Light | Dark |
|---|---|---|---|
| 캔버스 대비 | ≥ 3:1 | **최저 3.10** (yellow) | **최저 5.71** (violet) |
| `on-lane` 글자 대비 | ≥ 4.5:1 | 최저 4.62 (aqua) | 최저 6.07 (violet) |
| 이웃 쌍 정상 시각 ΔE | ≥ 15 | **최저 18.9** (0-1) | **최저 24.2** (0-1) |
| 이웃 쌍 제1·2색각 ΔE | 목표 ≥ 8, 하한 ≥ 6 | **최저 14.4** (4-5, protan) | **최저 17.5** (3-4, deutan) |
| 이웃 쌍 제3색각 ΔE | 참고 | 최저 6.0 (0-1) | 최저 8.6 (0-1) |

이웃 쌍 ΔE 전체(정상 / protan / deutan / tritan):

| 쌍 | Light | Dark |
|---|---|---|
| 0-1 | 18.9 / 18.0 / 17.9 / 6.0 | 24.2 / 22.7 / 22.3 / 8.6 |
| 1-2 | 34.7 / 28.4 / 24.0 / 18.3 | 37.6 / 32.2 / 25.8 / 22.2 |
| 2-3 | 29.4 / 25.6 / 29.6 / 25.4 | 25.0 / 23.3 / 25.8 / 19.8 |
| 3-4 | 31.4 / 19.0 / 14.6 / 34.1 | 33.9 / 26.9 / 17.5 / 39.4 |
| 4-5 | 22.0 / 14.4 / 17.4 / 24.9 | 25.5 / 18.7 / 18.3 / 27.6 |
| 5-6 | 24.8 / 24.8 / 19.1 / 10.0 | 25.5 / 25.3 / 20.3 / 11.0 |
| 6-7 | 32.3 / 30.1 / 21.0 / 18.9 | 38.5 / 37.4 / 29.1 / 23.2 |
| 7-0 | 28.0 / 25.2 / 29.1 / 18.9 | 35.7 / 32.3 / 37.4 / 24.0 |

- **만드는 방법.** 색상마다 OKLCH 명도를 따로 정하고(다크: 노랑 0.89, 하늘·청록 0.80~0.82, 파랑 0.72, 산호·자홍 0.70~0.71, 보라 0.68), 채도는 sRGB 한계의 96%까지 썼다. 순서는 azure를 0번에 고정하고 나머지 7개의 순열 5,040개를 모두 검사해, 이웃 쌍의 최소 ΔE(정상, 제1·2색각, 두 모드)가 가장 큰 축에 드는 것 가운데 앞 레인(0~3)이 차갑고 선명한 색이 되는 순서를 골랐다.
- **모든 쌍 기준은 쓰지 않는다.** 그래프에서 실제로 맞닿는 것은 이웃 레인뿐이다. 8색 모두를 서로 구분해야 하는 화면은 이 팔레트로 만들 수 없다. 레인은 위치(열)와 ref 알약 이름으로도 구분된다.

### 5.2 상태 색

상태 색은 범주형 팔레트가 아니다. 그래서 세 가지를 검사했다.

1. 의미를 가진 그래픽으로서의 대비(WCAG 1.4.11, ≥ 3:1)
2. **같은 맥락에 함께 나오는 색끼리**의 정상 시각 분리(≥ 15)
3. 색각 이상 분리(참고값으로만 기록)

**대비** (canvas / panel / raised)

| 토큰 | Light | Dark |
|---|---|---|
| staged | 5.17 / 4.95 / 4.54 | 9.44 / 8.96 / 8.14 |
| unstaged, prunable, warning | 4.85 / 4.64 / 4.25 | 9.96 / 9.45 / 8.58 |
| untracked, locked | 3.65 / 3.50 / 3.20 | 5.28 / 5.01 / 4.55 |
| conflicted, error | 5.66 / 5.42 / 4.96 | 5.54 / 5.26 / 4.77 |
| ahead, behind | 5.58 / 5.34 / 4.89 | 8.01 / 7.61 / 6.90 |
| accent | 5.66 / 5.42 / 4.96 | 9.52 / 9.03 / 8.20 |

모든 표면에서 3:1 이상이다. `surface.selection` 위에서는 light의 untracked(2.93)와 레인 7(2.48)이 3:1 아래로 내려가므로, 선택 행에서 이 둘의 심볼은 `text.secondary`(6.50)로 바꾼다([iconography.md §5](iconography.md#5-상태-심볼-매핑)).

**같은 맥락 안의 분리**

| 맥락 | 함께 나오는 토큰 | 정상 시각 최소 ΔE (기준 ≥ 15) | 색각 이상 최소 ΔE (참고) |
|---|---|---|---|
| 파일 행 (S-02) | staged, unstaged, untracked, conflicted | light **15.4** (unstaged↔untracked) · dark **18.9** (staged↔unstaged) | light 3.7 · dark 4.9 (staged↔unstaged) |
| 워크트리 행 (사이드바) | conflicted, ahead/behind, locked, prunable | light **15.4** (locked↔prunable) · dark **15.7** (ahead↔locked) | light 8.2 · dark 5.7 |

- 정상 시각 기준은 두 맥락 모두 통과한다.
- 색각 이상 분리는 하한 6에 못 미치는 쌍이 있다. 초록·주황·진홍으로 staged·unstaged·conflicted를 나타내는 관례를 지키는 한 피할 수 없다. 그래서 **심볼 모양과 텍스트 라벨을 필수 보조 수단으로 둔다** ([iconography.md §5](iconography.md#5-상태-심볼-매핑)). 파일 행은 그룹 머리(Staged, Unstaged …)와 종류 글자(A/M/D …)도 함께 있다.
- 후보 비교 기록 (#166):
  - 진홍을 빨강 쪽(색상각 16°)에 두면 light에서 주황과 ΔE 14.1이라 기준에 미달했다. 색상각 5°로 옮겼다.
  - 다크 진홍을 분홍 쪽(5°)에 두면 회색 untracked와 색각 이상 ΔE 1.1로 겹쳤다. 10°, 명도 0.675로 정했다(5.7).
  - 중립 회색을 어둡게(L 0.52) 두면 light에서 amber와 ΔE 13.1이었다. L 0.62로 밝혔다(심볼 전용이므로 3:1이면 된다).

### 5.3 diff

| 배경 | Light 텍스트 대비 | Dark 텍스트 대비 |
|---|---|---|
| added / removed | 14.77 / 14.43 | 11.51 / 12.70 |
| added-word / removed-word | 12.14 / 11.34 | 7.53 / 9.61 |
| hunk header | 15.13 | 12.02 |

텍스트는 `text.primary` 기준이다. 모두 7:1 이상이다.

### 5.4 작성자 아바타

| 검사 | 기준 | 결과 |
|---|---|---|
| 흰 이니셜 대비 | ≥ 4.5:1 (작은 굵은 글자) | **최소 5.07** (gold) · 최대 6.09 (violet) |
| light 표면 대비 (canvas / panel) | 참고 | 5.07–6.09 / 4.85–5.83 |
| dark 표면 대비 (canvas / panel) | 참고 | 2.93–3.51 / 2.78–3.33 |
| 정상 시각 분리 (모든 쌍) | 참고 | 최소 **8.9** (red↔orange), 다음 9.2 (orange↔gold), 10.2 (blue↔violet) |

- 8색을 같은 명도(OKLCH L 0.51–0.55)에 두어 흰 이니셜 대비를 고르게 맞췄다. 그 대가로 모든 쌍 분리는 범주형 기준(≥ 15)에 못 미친다. 아바타 색은 이름과 함께만 쓰는 보조 단서이므로 받아들인다.
- 그래프 노드에서는 레인 색 링이 원 경계를 맡는다. 사이드바와 칩의 16pt 아바타는 옆의 이름이 정보를 전달하므로 원 경계는 장식으로 본다.

### 5.5 컨트롤 위 텍스트

| 텍스트 | Light (`#ffffff`) | Dark (패널 위 흰색 6% = `#272a31`) |
|---|---|---|
| `text.primary` | 16.90 | 11.91 |
| `text.secondary` | 8.11 | 7.04 |
| `text.tertiary` | 5.27 | 4.36 → 컨트롤 안에서는 쓰지 않는다 |
| `text.on-accent` / 액센트 | 5.66 | 10.11 |

---

## 6. 변경 절차

1. 색을 바꾸려면 먼저 이슈(`type:feature` 또는 `type:docs`, `area:ui`)를 연다. 큰 변경은 Discussion에서 시작한다.
2. `design/tokens/tokens.json`을 고친다. semantic 층에는 새 hex를 쓰지 말고 primitive를 추가한 뒤 별칭으로 연결한다.
3. `python3 design/mockups/generator/colorcheck.py`를 실행해 `RESULT: all checks pass`를 확인한다. 상태 색을 바꿨으면 §5.2의 같은 맥락 분리도 다시 잰다.
4. §3의 표와 §5의 수치를 갱신한다. `design/mockups/generator/render.sh`로 목업을 다시 렌더링한다.
5. (Phase 3 이후) 생성기를 돌려 Asset Catalog와 Swift 파일을 갱신한다. light와 dark 스크린샷을 PR에 붙인다.
6. 레인 순서를 바꾸는 것은 색각 이상 안전성을 바꾸는 일이다. 순서만 바꾸더라도 3단계 검증을 다시 한다.
