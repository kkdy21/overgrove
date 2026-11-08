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
| [0004](0004-github-integration-gh-issues-only.md) | GitHub 연동은 gh CLI 위임, 이슈 조회만 | Accepted (§2는 [0023](0023-pull-request-status-from-gh-pr-list.md)으로 대체, GitHub 밖 제공자는 [0026](0026-gitlab-and-gitea-issue-providers.md)으로 확장) |
| [0005](0005-documentation-language.md) | 문서 언어 (내부 한국어, 외부 접점 영어) | Accepted |
| [0006](0006-zero-external-dependencies.md) | 외부 의존성 0개 | Accepted |
| [0007](0007-swift-format-toolchain.md) | 포맷·린트는 툴체인 내장 swift-format | Accepted |
| [0008](0008-git-invocation-model.md) | git 호출 모델 | Accepted |
| [0009](0009-repo-config-neutralization.md) | 저장소 설정 무력화 (RepoConfigInspector) | Accepted |
| [0010](0010-commit-graph-layout-in-app.md) | 커밋 그래프 레인을 앱에서 계산 | Accepted |
| [0011](0011-no-pull-in-v0-1.md) | v0.1에서 Pull 제외 | Accepted |
| [0012](0012-solo-maintainer-merge-policy.md) | 1인 메인테이너 머지 정책 | Accepted |
| [0013](0013-external-contributions-and-issue-claiming.md) | 외부 기여 모델과 이슈 선점 정책 | Accepted |
| [0014](0014-panel-theme-and-split-layout.md) | 메인 창의 자체 패널 테마와 사용자 정의 분할 레이아웃 | Accepted |
| [0015](0015-dependent-issues-stand-in.md) | 의존 이슈를 기다리지 않는다 (stand-in, 머지 순서는 `pr-policy`) | Accepted |
| [0016](0016-board-status-automation.md) | 보드 Status는 워크플로우가 project 전용 토큰으로 맞춘다 | Accepted |
| [0017](0017-design-token-generation.md) | 디자인 토큰은 Swift 스크립트로 Asset Catalog와 Swift 상수를 생성해 커밋 | Accepted |
| [0018](0018-launch-snapshot-disk-cache.md) | 실행 간 디스크 캐시는 표시 전용 워크트리 요약 스냅샷만 | Accepted |
| [0019](0019-user-chosen-git-executable.md) | 사용자가 고른 git 실행 파일을 믿는 조건 (경로·소유자·권한·버전 규칙, fail closed) | Accepted |
| [0020](0020-git-compatibility-matrix-in-ci.md) | git 호환성 매트릭스를 CI에서 돌리는 방법 (공식 tarball SHA-256 고정 빌드, 필수 검사 아님) | Accepted |
| [0021](0021-read-only-scope-after-v0-1.md) | v0.1 이후에도 조회 전용, 원격 쓰기는 `git fetch`만 | Accepted |
| [0022](0022-no-shell-proxy-env-vars.md) | 셸 프록시 환경 변수는 넘기지 않고 전역 `http.proxy`를 안내 | Accepted |
| [0023](0023-pull-request-status-from-gh-pr-list.md) | PR 상태는 `gh pr list` 하나로, head 저장소까지 맞을 때만 브랜치에 잇기 (ADR-0004 §2 대체) | Accepted |
| [0026](0026-gitlab-and-gitea-issue-providers.md) | GitLab·Gitea 이슈는 glab·gt에 위임, 그 CLI에 로그인된 호스트만 신뢰 (ADR-0004를 GitHub 밖 제공자로 확장) | Accepted |
