# Architecture Decision Records

> 상태: Accepted · 관련: [docs/README.md §2.5](../README.md)

결정은 여기에 번호를 붙여 기록한다. 새 ADR은 [`0000-template.md`](0000-template.md)를 복사해 다음 번호로 만든다. Claude Code를 쓰면 `/adr-new` skill이 번호와 링크를 정리해 준다.

## 규칙

- **상태 값**: `Proposed` → `Accepted` 또는 `Rejected`. 나중에 바뀌면 기존 ADR을 고치지 않고 새 ADR을 쓴 뒤, 기존 ADR 상태를 `Superseded by ADR-NNNN`으로 바꾼다.
- **이슈 연결**: 관련 `type:decision` 이슈에 ADR 링크를 남기고, ADR 머리말에 이슈 번호를 적는다.
- **승인 시점**: Phase 게이트에서 `Proposed` ADR을 함께 승인받는다 ([process/phase-gates.md](../process/phase-gates.md)).

## 목록

| 번호 | 제목 | 상태 |
|---|---|---|
| [0001](0001-product-name-overgrove.md) | 제품명 Overgrove | Accepted |
| [0002](0002-license-mit.md) | 라이선스 MIT | Accepted |
| [0003](0003-minimum-macos-14.md) | 최소 macOS 14 | Accepted |
| [0004](0004-github-integration-gh-issues-only.md) | GitHub 연동은 gh CLI 위임, 이슈 조회만 | Accepted |
| [0005](0005-documentation-language.md) | 문서 언어 (내부 한국어, 외부 접점 영어) | Accepted |
| [0006](0006-zero-external-dependencies.md) | 외부 의존성 0개 | Accepted |
| [0007](0007-swift-format-toolchain.md) | 포맷·린트는 툴체인 내장 swift-format | Accepted |
| [0008](0008-git-invocation-model.md) | git 호출 모델 | Accepted |
| [0009](0009-repo-config-neutralization.md) | 저장소 설정 무력화 (RepoConfigInspector) | Accepted |
| [0010](0010-commit-graph-layout-in-app.md) | 커밋 그래프 레인을 앱에서 계산 | Accepted |
| [0011](0011-no-pull-in-v0-1.md) | v0.1에서 Pull 제외 | Accepted |
| [0012](0012-solo-maintainer-merge-policy.md) | 1인 메인테이너 머지 정책 | Accepted |
| [0013](0013-external-contributions-and-issue-claiming.md) | 외부 기여 모델과 이슈 선점 정책 | Accepted |
