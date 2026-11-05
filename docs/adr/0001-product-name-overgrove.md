# ADR-0001: 제품명을 Overgrove로 정한다

> 상태: Accepted · 날짜: 2026-11-05 · 관련: [docs/README.md §2.1](../README.md)

## 맥락

HANDOFF는 가칭 `WorktreeDeck`을 쓰고 Phase 1에서 이름을 확정하도록 했다. 이름은 공개 저장소 URL, Xcode 프로젝트·타깃, Bundle ID, 문서 전체에 퍼지므로 공개 전에 확정해야 한다. 공개 이후 바꾸면 검색 색인과 링크가 남아 비용이 크다.

평가 기준은 세 가지다.

1. **앱처럼 들려야 한다.** 라이브러리나 CLI 유틸리티처럼 들리면 안 된다.
2. **GitHub에서 git·worktree 도구와 이름이 겹치지 않아야 한다.**
3. **제품 콘셉트(여러 워크트리를 한눈에 내려다봄)를 은유해야 한다.**

## 결정

제품명은 **Overgrove**로 한다. over(위에서) + grove(작은 숲)를 합친 조어로, 숲처럼 늘어선 워크트리를 위에서 내려다본다는 뜻이다.

| 항목 | 값 |
|---|---|
| GitHub 저장소 | `kkdy21/overgrove` |
| Xcode 프로젝트 / 앱 타깃 / 테스트 타깃 | `Overgrove.xcodeproj` / `Overgrove` / `OvergroveTests` |
| Bundle ID | `io.github.kkdy21.overgrove` |

## 대안

2026-11-05에 GitHub 저장소 이름 검색(`in:name`)으로 충돌을 확인했다.

| 후보 | 검토 결과 | 판단 |
|---|---|---|
| WorktreeDeck | 충돌 0건. 하지만 "워크트리 전용 라이브러리"처럼 들린다는 메인테이너 의견 | 기각 |
| Canopy | git 클라이언트 성격의 `GitCanopy` 저장소가 있음 | 기각 (충돌) |
| Grove | `grove-git-client`, Grove(git worktree workspace orchestrator) 등 존재 | 기각 (충돌) |
| Treeline | `git-treeline` 조직의 CLI 도구가 있음 | 기각 (충돌) |
| Coppice | git worktree를 관리하는 데스크톱 앱이 이미 있음 | 기각 (직접 충돌) |
| Overstory | git worktree 기반 AI 코딩 에이전트 오케스트레이션 도구(1.3k★)가 있음 | 기각 (충돌) |
| Copse | 충돌 0건. 단어가 생소해 의미 전달과 검색에 약함 | 기각 |
| Worktable | 충돌 낮음. '작업대'로 읽혀 git 도구라는 점이 드러나지 않음 | 기각 |
| Espalier | 콘셉트는 잘 맞지만(가지를 평면에 펼침) 철자가 어렵고 AI 코딩 도구 저장소와 겹침 | 기각 |
| Treetop | 쉬운 단어지만 유명한 Ruby 파서 라이브러리와 같은 이름 | 기각 |
| **Overgrove** | 무관한 0★ 저장소 1개뿐 | **채택** |

## 결과

- 검색 결과에서 이름을 독점하기 쉽고, 앱 이름처럼 들린다.
- 조어라서 처음 보는 사람은 뜻을 바로 알기 어렵다. README 첫 문장에서 "Git worktree dashboard for macOS"로 보완한다.
- 상표 검색은 하지 않았다. 배포 바이너리나 상용 판매가 없는 오픈소스라 위험은 낮다고 본다. 바이너리 배포를 검토하게 되면 다시 확인한다.

## 후속 작업

- [ ] README 첫 줄에 한 줄 설명 추가 (Phase 5)
- [ ] 앱 아이콘과 이름의 은유 일치 확인 ([design/iconography.md](../design/iconography.md))
