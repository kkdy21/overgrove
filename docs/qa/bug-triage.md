# 버그 트리아지

> 상태: Accepted (Phase 2 게이트, 2026-11-05) · 관련: [process.md](process.md), [issues.md](../process/issues.md), [SECURITY.md](../../SECURITY.md), [security-review.md](../design/security-review.md)

새 버그 이슈를 분류하는 기준이다. 목표는 두 가지다. **심각도(S)는 사용자가 받는 영향**을, **priority 라벨은 처리 순서**를 나타낸다. 둘은 보통 같이 움직이지만 다를 수도 있다. 예를 들어 영향은 작지만 릴리스를 막는 회귀는 S3라도 p1이 될 수 있다.

---

## 1. 심각도

| 심각도 | 정의 | 예 | 기본 priority |
|---|---|---|---|
| **S1 치명** | 보안 원칙 위반, 데이터 손상, 사용자 저장소 변경, 앱을 쓸 수 없음 | 악성 저장소 설정이 실행됨(canary 생성), 조회 중 `.git/index`나 ref가 바뀜, 자격 증명이 화면·로그에 원문으로 나옴, 실행 즉시 크래시 | `priority:p0` |
| **S2 높음** | 핵심 기능(G1–G6)이 틀린 결과를 보여주거나 동작하지 않음. 우회 방법이 없음 | 워크트리 누락, staged/unstaged 분류 오류, ahead/behind가 틀림, 특수 파일명에서 크래시, fetch가 멈춘 채 타임아웃이 안 걸림 | `priority:p0` 또는 `p1` |
| **S3 보통** | 기능이 일부 틀리거나 불편함. 우회 방법이 있음. 성능 예산 위반 | 특정 화면의 레이아웃 깨짐, 정렬 오류, PB 예산 초과, 이슈 번호 매칭 오탐 | `priority:p1` 또는 `p2` |
| **S4 낮음** | 외관, 문구, 사소한 불일치 | 오탈자, 아이콘 정렬, 툴팁 문구 | `priority:p2` |

심각도는 이슈 본문 첫 줄에 `Severity: S2`처럼 적는다. 별도 라벨은 만들지 않는다 (라벨 체계는 [labels.json](../../.github/labels.json)이 원본).

---

## 2. 트리아지 절차

새 이슈에는 템플릿이 `type:bug`, `status:triage`를 붙인다. 메인테이너(또는 Claude Code의 `/issue-triage`)가 다음 순서로 처리한다.

1. **보안인지 먼저 본다.** 위협 모델(T1–T18)에 해당하거나 악용 방법이 적혀 있으면 §4로 간다.
2. **중복을 확인한다.** 중복이면 원본 이슈를 링크하고 `resolution:duplicate`로 닫는다.
3. **재현한다.** 픽스처([fixtures.md](../testing/fixtures.md))에서 재현을 시도한다.
   - 재현되지 않고 정보도 부족하면 필요한 정보를 묻는다. 무엇이 필요한지 구체적으로 적는다. 예: git 버전, macOS 버전, `git status --porcelain=v2 -z` 출력의 해당 레코드(경로는 가려도 됨).
   - 14일 동안 응답이 없으면 `resolution:invalid`로 닫고, 정보가 오면 다시 연다.
4. **범위 안인지 본다.** 비목표(N1–N7)에 해당하는 요청이면 `resolution:wontfix`로 닫는다. 기능 요청으로 바꿀 만하면 Discussion이나 `later` 이슈로 옮긴다.
5. **분류한다.**
   - 심각도를 정하고 `priority:*`, `area:*`, `phase:*`를 붙인다.
   - 마일스톤을 정한다. S1·S2는 현재 마일스톤, 나머지는 판단에 따른다.
   - `status:triage`를 뗀다.
6. **재현 테스트 계획을 적는다.** 어느 층의 테스트로 재현할지(PAR, INT, SEC, QA) 한 줄 적는다. 이후 흐름은 [process.md §4](process.md)를 따른다.

| 응답 목표 | S1 | S2 | S3 | S4 |
|---|---|---|---|---|
| 트리아지 | 24시간 | 3일 | 7일 | 14일 |
| 수정 착수 | 즉시 (다른 작업 중단) | 현재 마일스톤 안 | 계획에 따라 | 여유 있을 때 |

1인 프로젝트이므로 응답 목표는 노력 목표이며 약속(SLA)이 아니다. SECURITY.md의 보안 제보 응답 기준은 그 문서를 따른다.

---

## 3. 라벨 조합 예

| 상황 | 라벨 |
|---|---|
| 파서가 개행이 든 파일명을 잘못 나눔 | `type:bug`, `area:parser`, `priority:p0`, `phase:dev` + 본문 `Severity: S2` |
| 그래프 첫 페이지가 commit-graph 없는 저장소에서 1.4초 | `type:bug`, `area:ui`, `priority:p1` + `Severity: S3` (PB-3b 위반) |
| 다크 모드에서 배지 대비 부족 | `type:bug`, `area:ui`, `priority:p2` + `Severity: S4` |
| 이슈 패널이 GitHub Enterprise 원격을 인식하지 못함 | 비목표에 가까움 → `later` 마일스톤의 `type:feature`로 전환 |

---

## 4. 보안 버그

**보안 취약점은 공개 이슈로 다루지 않는다.**

- 제보자는 [SECURITY.md](../../SECURITY.md)의 안내대로 GitHub **Private vulnerability reporting**(Security › Advisories › Report a vulnerability)을 쓴다. 이슈 템플릿 선택 화면에도 이 링크가 있다 (`.github/ISSUE_TEMPLATE/config.yml`).
- 공개 이슈로 들어온 보안 제보는 다음 순서로 처리한다.
  1. 악용 방법이 적혀 있으면 메인테이너가 내용을 숨긴다(이슈 편집 또는 숨김 처리).
  2. 제보자에게 비공개 경로로 옮겨 달라고 요청한다.
  3. 공개 이슈는 상세 없이 닫는다.
- 비공개 advisory 안에서 진행하는 것:
  - 심각도는 기본 S1이다.
  - 재현 테스트(SEC-Tn-xx)를 쓴다. 새 위협이면 security-review.md에 T19 이후 번호를 추가한다.
  - 수정은 advisory의 private fork에서 하거나, 공개 PR에서 보안 영향을 드러내지 않는 제목으로 한다. 어느 쪽으로 할지는 메인테이너가 정한다.
- 수정이 배포되면 advisory를 공개하고 CHANGELOG의 `Security` 항목에 적는다.
- Claude Code는 보안 제보 내용을 공개 이슈, PR, 커밋 메시지, Discussion에 옮겨 적지 않는다.

**악성 저장소 관련 버그의 판정 기준.** canary 방식으로 "보안 인자를 적용한 앱 명령이 저장소 설정을 실행했다"가 재현되면 S1이다. 사용자가 직접 실행한 git 명령이나 앱 밖 도구의 동작은 Overgrove의 버그가 아니다. 다만 앱이 그런 위험을 알리지 못했다면 S3 개선 사항으로 다룬다.
