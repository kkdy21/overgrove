# 릴리스

> 상태: Accepted · 관련: [qa/release-checklist.md](../qa/release-checklist.md), [CHANGELOG.md](../../CHANGELOG.md), ADR-0002

## 1. 버전 정책

- [Semantic Versioning](https://semver.org/)을 따른다. `0.x` 동안은 minor 버전에도 호환성을 깨는 변경이 들어갈 수 있다.
- 태그 형식은 `vMAJOR.MINOR.PATCH`(예: `v0.1.0`)다. 마일스톤 이름과 같다.
- 배포물은 **소스만** 낸다. 서명·공증 바이너리, App Store 배포는 하지 않는다(N2).

## 2. 변경 기록

- `CHANGELOG.md`는 [Keep a Changelog](https://keepachangelog.com/) 형식이다.
- 사용자에게 보이는 변경이 있는 PR은 `Unreleased`에 한 줄을 추가한다(PR 체크리스트 항목).
- 분류는 Added / Changed / Deprecated / Removed / Fixed / Security.
- 보안 수정은 advisory가 공개된 뒤에 상세를 적는다.

## 3. 절차

1. 릴리스 이슈를 만든다: `chore(release): v0.1.0`(`phase:release`).
2. [release-checklist.md](../qa/release-checklist.md)를 이슈의 완료 조건으로 복사해 하나씩 확인한다.
3. 릴리스 PR(`chore/<n>-release-v0-1-0`)을 연다:
   - `CHANGELOG.md`의 `Unreleased`를 `[0.1.0] - YYYY-MM-DD`로 바꾸고 비교 링크를 갱신한다.
   - README의 상태 배지와 문구를 갱신한다.
4. 머지 후 `main`에서 서명된 annotated tag를 만든다(메인테이너):
   ```sh
   git switch main && git pull --ff-only
   git tag -s v0.1.0 -m "Overgrove v0.1.0"
   git push origin v0.1.0
   ```
   태그 푸시는 룰셋의 브랜치 보호 대상이 아니다. 태그 보호 룰셋은 v0.1.0 전에 추가를 검토한다.
5. GitHub Release를 만든다. GitHub이 자동으로 붙이는 소스 아카이브만 쓴다:
   ```sh
   gh release create v0.1.0 --repo kkdy21/overgrove --title "Overgrove v0.1.0" --notes-file <changelog-section>
   ```
6. Announcements Discussion에 공지하고, 마일스톤을 닫는다.

## 4. 핫픽스

`main`에서 `fix/<n>-<slug>`로 고치고 PATCH 버전을 올린다. 0.x 동안은 지난 버전용 유지보수 브랜치를 두지 않는다. 지원 범위는 [SECURITY.md](../../SECURITY.md)를 따른다.
