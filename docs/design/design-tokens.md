# 디자인 토큰 (Design Tokens)

> 상태: Accepted (Phase 2 게이트, 2026-11-05) · 관련: [`design/tokens/tokens.json`](../../design/tokens/tokens.json), [screens.md](screens.md), [interaction.md §6](interaction.md#6-접근성), [iconography.md](iconography.md), ADR-0006, ADR-0010

색, 간격, 크기, 글꼴, 움직임의 **단일 원본은 [`design/tokens/tokens.json`](../../design/tokens/tokens.json)이다.** 이 문서는 그 구조와 규칙, 검증 결과, SwiftUI로 옮기는 계획을 설명한다. 값이 서로 다르면 JSON이 맞고 이 문서를 고친다.

---

## 1. 원칙

1. **시스템이 먼저다.** 표면, 텍스트, 구분선, 선택, 포커스, 액센트는 macOS 시스템 색(`NSColor.labelColor` 등)을 쓴다. 그러면 다크 모드, 사용자 액센트 색, Increase Contrast, 앞으로의 OS 변화가 자동으로 반영된다. JSON의 hex 값은 문서와 목업에 쓰는 근삿값일 뿐이다.
2. **앱 고유 색은 세 묶음뿐이다.** 상태 색(status), 그래프 레인 색(graph.lane), diff 배경색(diff). 그 밖의 색이 필요하면 먼저 시스템 색으로 해결할 수 있는지 본다.
3. **브랜드 색은 앱 아이콘에만 쓴다.** `primitive.color.forest.*`는 아이콘과 README 마크용이다. 앱 UI의 강조색은 사용자의 시스템 액센트 색이다. 앱이 액센트 색을 정하지 않는다.
4. **색은 의미를 혼자 지지 않는다.** 모든 상태 색은 SF Symbol과 텍스트를 함께 쓴다 ([iconography.md §5](iconography.md#5-상태-심볼-매핑), [interaction.md §6.2](interaction.md#62-색에만-의존하지-않는다)).
5. **GitKraken을 포함한 다른 제품의 팔레트를 쓰지 않는다.** 레인 팔레트는 데이터 시각화용 범주형 기준 팔레트에서 출발해 아래 §5 방식으로 다시 검증했다. 청록·보라 계열의 브랜드 톤을 주조색으로 쓰지 않는다.

---

## 2. 구조

[W3C Design Tokens Community Group](https://tr.designtokens.org/format/) 형식을 따른다.

```
primitive/          원시 값. 의미 없음. 앱 코드에서 직접 참조 금지
  color.forest.*            브랜드 그린 (아이콘 전용)
  color.status.*            상태 색 단계 (green-600, amber-400 …)
  color.lane.*              레인 색상군의 light/dark 단계
  color.diff.*              diff 배경 단계
  color.system-fallback.*   macOS 시스템 색의 근삿값 (문서·목업용)
semantic/           역할. 앱 코드가 참조하는 유일한 층
  color.surface.*  color.text.*  color.border.*  color.accent
  color.status.*   color.graph.*  color.diff.*
  spacing.*  radius.*  typography.*  size.*  motion.*  opacity.*
```

### 2.1 라이트·다크 모드

DTCG 형식에는 아직 모드 개념이 없다. 그래서 아래처럼 표기한다.

- `$value`는 **light 모드** 값이다.
- dark 값은 `$extensions["io.github.kkdy21.overgrove"].modes.dark`에 둔다.
- 런타임에 시스템 색으로 풀어야 하는 토큰은 같은 확장에 `appkit`(예: `NSColor.labelColor`)이나 `swiftui` 키로 대응 API를 적는다.

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
| primitive는 `색상군-단계`. 단계가 클수록 어둡다 | `green-600`, `amber-400` |
| semantic은 역할 이름. 색상 이름을 쓰지 않는다 | `status.conflicted` (O), `status.red` (X) |
| semantic 색은 원칙적으로 별칭(`{…}`)만 쓴다. 예외는 런타임에 알파를 섞는 `surface.wip-row`와 시스템 색 근삿값 | |
| 그래프 레인은 숫자 인덱스 | `graph.lane.0` ~ `graph.lane.7` |
| 앱 코드는 semantic만 참조한다 | `Tokens.Color.statusStaged` (생성 이름은 §4) |

---

## 3. 토큰 요약

### 3.1 상태 색

| 토큰 | 의미 | Light | Dark | 함께 쓰는 심볼 |
|---|---|---|---|---|
| `status.staged` | 스테이징됨 | `#0b8a0b` | `#30c048` | `checkmark.circle.fill` |
| `status.unstaged` | 스테이징 안 된 변경 | `#b66c18` | `#f5a524` | `pencil` |
| `status.untracked` | 추적 안 함 | `#5a5955` | `#a19f97` | `questionmark.circle` |
| `status.conflicted` | 충돌 | `#c8175a` | `#fb5a8a` | `exclamationmark.triangle.fill` |
| `status.ahead` | upstream보다 앞섬 | `#2563c9` | `#4f9bf0` | `arrow.up` |
| `status.behind` | upstream보다 뒤처짐 | `#2563c9` | `#4f9bf0` | `arrow.down` |
| `status.locked` | 잠긴 워크트리 | `#5a5955` | `#a19f97` | `lock.fill` |
| `status.prunable` | 디렉터리가 사라진 워크트리 | `#b66c18` | `#f5a524` | `questionmark.folder` |
| `status.ok` / `warning` / `error` | 점검·보안 상태, 명령 실패 | staged / unstaged / conflicted와 같은 단계 | | `checkmark.shield` 등 |

**같은 색을 일부러 공유하는 쌍.** 아래 쌍은 같은 맥락에 함께 나오지 않거나, 색이 아닌 수단이 이미 의미를 전달한다.

- `ahead` = `behind`: 화살표 방향이 의미를 전달한다. 색은 "upstream과 다르다"만 알린다.
- `untracked` = `locked`: 파일 행과 워크트리 행이라는 서로 다른 맥락에 나온다.
- `unstaged` = `prunable` = `warning`: 마찬가지로 맥락이 다르다. 게다가 워크트리 행의 변경 수는 색을 쓰지 않는다.

충돌 색은 빨강이 아니라 진홍(crimson)이다. 빨강을 쓰면 light 모드에서 주황 `unstaged`와 정상 시각으로도 구분하기 어려웠다(ΔE 13~14, §5.2).

### 3.2 그래프 레인

| 인덱스 | 색상군 | Light | Dark |
|---|---|---|---|
| 0 | green | `#008300` | `#008300` |
| 1 | blue | `#2a78d6` | `#3987e5` |
| 2 | red | `#e34948` | `#e66767` |
| 3 | violet | `#6250d6` | `#9085e9` |
| 4 | orange | `#eb6834` | `#d95926` |
| 5 | aqua | `#1baf7a` | `#199e70` |
| 6 | yellow | `#eda100` | `#c98500` |
| 7 | magenta | `#e87ba4` | `#d55181` |

- **순서가 안전장치다.** 이웃한 레인은 항상 연속한 인덱스를 받는다. 8개를 넘으면 7 다음에 0이 온다. 그래서 순서 검증에 **7↔0 wrap 쌍**까지 넣었다 (§5.1).
- 레인 색 인덱스는 레인이 생길 때 `열 인덱스 mod 8`로 정하고, 스크롤해도 바뀌지 않는다. 색은 브랜치를 따라가고 화면상의 순위를 따라가지 않는다. 알고리즘은 ADR-0010과 [architecture/overview.md](../architecture/overview.md)에 있다.
- 0번(green)은 보통 기본 브랜치의 레인이다. 아이콘의 숲 이미지와 이어지도록 골랐다.
- 노드는 표면 색 2px 링(`graph.node-ring`)으로 감싸 지나가는 간선과 떨어뜨린다. WIP 노드는 레인 색을 쓰지 않는 점선 중립 노드다(`graph.wip-node`).

### 3.3 diff

| 토큰 | Light | Dark |
|---|---|---|
| `diff.added-bg` | `#e3f4e1` | `#173a22` |
| `diff.removed-bg` | `#fbe6ea` | `#45192a` |
| `diff.added-word-bg` | `#bfe6b9` | `#24603a` |
| `diff.removed-word-bg` | `#f6c2cc` | `#7a2a45` |
| `diff.hunk-header-bg` | `#eaf0fb` | `#1d2a40` |
| `diff.gutter-added` / `gutter-removed` | `status.staged` / `status.conflicted` 별칭 | |

### 3.4 간격·모서리·크기·글꼴·움직임

| 묶음 | 값 |
|---|---|
| `spacing` | xxs 2 · xs 4 · sm 8 · md 12 · lg 16 · xl 24 · xxl 32 (px) |
| `radius` | sm 4 (배지, ref 알약) · md 6 (버튼, 시스템 컨트롤과 같음) · lg 10 (카드, popover) · pill |
| `size` | 사이드바 행 24, 그래프 행 24 (고정, 가상화 전제), 파일 행 22, 레인 폭 14, 노드 8 (merge 6, HEAD 10), 간선 2, 노드 링 2, 최소 클릭 영역 20. 패널 폭: 사이드바 200/240/360, 상세 280/340, 그래프 최소 420. 창 최소 960×600 |
| `typography` | macOS 텍스트 스타일에 대응한다: body 13, headline 13 bold, title(상세 제목) 15 semibold, callout 12, section-header 11 bold, caption 10, mono 12 (SF Mono), mono-small 11. **앱 코드는 포인트 크기가 아니라 SwiftUI 텍스트 스타일을 쓴다** |
| `motion` | fast 120ms · standard 200ms · slow 350ms · easing `cubic-bezier(0.2, 0, 0, 1)`. Reduce Motion이면 크로스페이드나 애니메이션 없음 |
| `opacity` | disabled 0.4 · stale 0.6 (새로고침 실패 후 이전 데이터) |

---

## 4. SwiftUI 매핑 계획 (Phase 3 결정 사항)

외부 도구 0개 원칙(ADR-0006) 아래에서 JSON을 앱으로 옮기는 방법을 Phase 3 첫 UI 이슈에서 확정한다. 확정되면 ADR로 남긴다.

| 선택지 | 장점 | 단점 |
|---|---|---|
| **A. Swift 생성 스크립트 (권장)** — `scripts/tokens/generate.swift`(툴체인만 사용)가 JSON을 읽어 (1) `Overgrove/Resources/Assets.xcassets/Tokens/*.colorset`과 (2) `Overgrove/DesignSystem/Tokens.generated.swift`를 만든다. 결과물은 커밋한다 | 원본이 하나다. 색 세트에 light/dark/High Contrast 변형을 담을 수 있다. 외부 도구가 필요 없다 | 생성기를 유지해야 한다 |
| B. 손으로 관리 | 시작이 가장 빠르다 | JSON과 앱이 어긋나기 쉽다 |
| C. Style Dictionary 같은 외부 도구 | 기능이 풍부하다 | Node 의존성이 생긴다. ADR-0006 위반 |

권장안 A의 세부:

- 시스템 색에 대응하는 토큰(`appkit` 키가 있는 것)은 색 세트를 만들지 않는다. 대신 `Color(nsColor: .labelColor)` 같은 참조 코드를 생성한다.
- 앱 고유 색(status, graph.lane, diff)만 색 세트로 만든다. 색 세트마다 Any / Dark / High Contrast / Dark High Contrast 네 변형을 둔다. High Contrast 변형은 Phase 3에서 값을 정하고, 배경 대비 4.5:1 이상이어야 한다.
- 간격, 크기, 모서리, 움직임은 `enum Tokens { enum Spacing { static let sm: CGFloat = 8 } … }` 형태로 만든다. 글꼴은 `Font.body` 같은 텍스트 스타일 참조로 만든다.
- 어긋남 방지: CI에서 생성기를 다시 돌린 뒤 `git diff --exit-code`로 결과물이 최신인지 확인한다. 테스트로 할지 CI 단계로 할지는 [testing/test-strategy.md](../testing/test-strategy.md)와 맞춘다.

---

## 5. 검증 결과

모든 수치는 2026-11-05에 측정했다.

- **도구**: Claude Code `dataviz` 스킬의 팔레트 검증기
- **측정 방식**
  - ΔE: OKLab 유클리드 거리 ×100
  - 색각 이상: Machado–Oliveira–Fernandes 2009, severity 1.0, protan·deutan 중 최솟값
  - 대비: WCAG 2 대비율
- **표면 색**: light `#ffffff`(content) · `#ececec`(window) · `#e8e8e8`(sidebar 근사), dark `#1e1e1e` · `#323232` · `#2a2a2a`

검증기는 저장소에 포함되어 있지 않다. 저장소 안에서 같은 검사를 재현하는 스크립트(`scripts/tokens/check-palette.swift`, 외부 도구 없음)를 Phase 3 이슈로 제안한다.

### 5.1 그래프 레인 팔레트

범주형 팔레트 기준(같은 순서의 이웃 쌍 검사)으로 판정했다. 순환 구조를 반영해 **8개 + 첫 슬롯을 다시 붙인 9개 목록**으로 7↔0 wrap 쌍까지 검사했다.

| 검사 | 기준 | Light | Dark |
|---|---|---|---|
| 명도 대역 (OKLCH L) | light 0.43–0.77 / dark 0.48–0.67 | PASS | PASS |
| 채도 하한 (OKLCH C) | ≥ 0.10 | PASS | PASS |
| 색각 이상 분리 (이웃 쌍) | 목표 ≥ 8, 하한 ≥ 6 | **9.1** (yellow↔aqua, protan) · tritan 5.8 | **8.4** (yellow↔aqua, protan) · tritan 8.7 |
| 정상 시각 분리 (이웃 쌍) | ≥ 15 (필수) | **19.6** (magenta↔yellow) | **19.3** (magenta↔yellow) |
| 표면 대비 | ≥ 3:1, 미만이면 완화 조건 필요 | WARN: aqua 2.82, yellow 2.17, magenta 2.69 | PASS (전부 ≥ 3:1) |

슬롯별 대비 (content 표면 기준):

| 슬롯 | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| Light vs `#ffffff` | 4.95 | 4.42 | 3.95 | 5.77 | 3.20 | 2.82 | 2.17 | 2.69 |
| Dark vs `#1e1e1e` | 3.37 | 4.58 | 5.16 | 5.33 | 4.29 | 4.90 | 5.43 | 4.23 |

- **순서 선정.** green을 0번에 고정하고 나머지 7개의 순열 5,040개를 모두 검사했다. 두 모드에서 모든 필수 기준을 통과한 순환 순서는 112개였다. 최상위 묶음(색각 이상 최소 8.4, 정상 시각 최소 19.3)에 든 4개 가운데, light 모드에서 대비 3:1 이상인 색이 앞쪽 0~3번에 모두 오는 순서를 골랐다. 레인은 앞 번호일수록 자주 나오기 때문이다.
- **light 모드 대비 완화 조건.** 슬롯 5~7은 light 표면에서 3:1에 못 미친다. 그래프의 모든 행에는 SHA, 제목, ref 알약 텍스트가 있고, 레인은 위치로도 구분된다. 그래서 "보이는 라벨 또는 표 형태"라는 완화 조건을 만족한다. 이 조건은 설계 제약이다. 레인 색만으로 정보를 전달하는 화면(예: 범례 없는 미니맵)을 만들면 다시 검증해야 한다.
- **모든 쌍 기준은 쓰지 않는다.** 그래프에서 실제로 맞닿는 것은 이웃 레인뿐이므로 이웃 쌍 기준을 적용했다. 8색 모두를 서로 구분해야 하는 화면은 이 팔레트로 만들 수 없다.

### 5.2 상태 색

상태 색은 범주형 팔레트가 아니다. 그래서 다음 세 가지를 검사했다. (1) 의미를 가진 그래픽으로서의 대비(WCAG 1.4.11, ≥ 3:1). (2) **같은 맥락에 함께 나오는 색끼리**의 정상 시각 분리(≥ 15). (3) 색각 이상 분리는 참고값으로만 기록했다.

**대비**

| 토큰 | Light content / window / sidebar | Dark content / window / sidebar |
|---|---|---|
| staged | 4.51 / 3.82 / 3.68 | 6.95 / 5.35 / 5.99 |
| unstaged, prunable, warning | 4.08 / 3.45 / 3.33 | 8.17 / 6.28 / 7.03 |
| untracked, locked | 7.01 / 5.94 / 5.72 | 6.29 / 4.84 / 5.41 |
| conflicted, error | 5.64 / 4.77 / 4.60 | 5.50 / 4.23 / 4.74 |
| ahead, behind | 5.67 / 4.80 / 4.62 | 5.78 / 4.44 / 4.98 |

모든 표면에서 3:1 이상이다. 최솟값은 light 사이드바 위의 amber 3.33이다.

**같은 맥락 안의 분리**

| 맥락 | 함께 나오는 토큰 | 정상 시각 최소 ΔE (기준 ≥ 15) | 색각 이상 최소 ΔE (참고) |
|---|---|---|---|
| 파일 행 (S-02) | staged, unstaged, untracked, conflicted | light **18.0** (unstaged↔conflicted) · dark **16.8** (unstaged↔untracked) | light 3.0 · dark 2.3 (staged↔unstaged) |
| 워크트리 행 (사이드바) | conflicted, ahead/behind, locked, prunable | light **18.0** (conflicted↔prunable) · dark **16.0** (ahead↔locked) | light 3.5 · dark 2.5 (conflicted↔locked) |

- 정상 시각 기준은 두 맥락 모두 통과한다.
- 색각 이상 분리는 하한 6에 못 미친다. 초록·주황·진홍으로 staged·unstaged·conflicted를 나타내는 관례를 지키는 한 피할 수 없는 결과다. 그래서 **심볼 모양과 텍스트 라벨을 필수 보조 수단으로 둔다** ([iconography.md §5](iconography.md#5-상태-심볼-매핑)). 상태 색은 어디서도 의미를 혼자 지지 않는다.
- 후보 비교 기록:
  - 빨강 `#d0263c`: light에서 주황과 ΔE 12.5~14.3이라 기준에 미달
  - 청록 쪽 초록 `#0e8a5f`: untracked 회색과 ΔE 11.9라 기준에 미달
  - ahead와 behind에 파랑·보라를 따로 주는 안: ΔE 9.8~10.5, 색각 이상 1.7로 사실상 같은 색. 그래서 같은 색으로 합치고 방향 화살표에 의미를 맡겼다

### 5.3 diff

| 배경 | Light 텍스트 대비 | Dark 텍스트 대비 |
|---|---|---|
| added / removed | 14.66 / 14.11 | 10.28 / 12.01 |
| added-word / removed-word | 12.21 / 10.83 | 6.09 / 7.63 |
| hunk header | 14.71 | 11.74 |

텍스트는 `text.primary` 근삿값(light `#1d1d1f`, dark `#e8e8e6`) 기준이다. 모두 4.5:1 이상이고, 단어 강조 dark를 빼면 7:1 이상이다.

---

## 6. 변경 절차

1. 색을 바꾸려면 먼저 이슈(`type:feature`, `area:ui`)를 연다. 큰 변경은 Discussion에서 시작한다.
2. `design/tokens/tokens.json`을 고친다. semantic 층에는 새 hex를 쓰지 말고 primitive를 추가한 뒤 별칭으로 연결한다.
3. 다시 검증한다.
   - 레인: 이웃 쌍 + wrap 쌍, light·dark 모두 (§5.1 기준)
   - 상태: 세 표면 대비 ≥ 3:1, 같은 맥락 안 정상 시각 ΔE ≥ 15 (§5.2)
   - diff·텍스트: 대비 ≥ 4.5:1
4. §5의 수치와 §3의 표를 갱신한다. 목업([`design/mockups/`](../../design/mockups/))이 있으면 다시 렌더링한다.
5. (Phase 3 이후) 생성기를 돌려 Asset Catalog와 Swift 파일을 갱신한다. light와 dark 스크린샷을 PR에 붙인다.
6. 레인 순서를 바꾸는 것은 색각 이상 안전성을 바꾸는 일이다. 순서만 바꾸더라도 3단계 검증을 다시 한다.
