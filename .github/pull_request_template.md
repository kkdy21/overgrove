<!--
Title: Conventional Commits in English, e.g. `feat(parser): parse porcelain v2 rename records`.
It becomes the squash-commit title on main. / PR 제목은 영어 Conventional 형식으로 쓰세요.
-->

Closes #

<!--
Needs another unfinished issue? Add a line "Depends on #<issue>" below this comment for each one that is not already
under "## 의존성" in the linked issue, and keep this PR as a draft until they are done. Mark temporary code for them
with STAND-IN(#<issue>) comments. See CONTRIBUTING.md, "When your issue depends on unfinished work".
-->

## Summary / 요약

<!-- What changed and why. Link docs, ADRs, screens (S-xx), threats (T-xx). -->

## How it was verified / 검증 방법

<!-- Commands you ran, tests added, fixtures used, screenshots for UI. -->

- [ ] `xcodebuild test` passes locally (or N/A: no app code touched)
- Local toolchain: <!-- The Xcode and macOS you built and tested with, e.g. "Xcode 26.1 (17B55), macOS 26.1", from `xcodebuild -version` and `sw_vers -productVersion`. N/A when no app code is touched. -->
- [ ] New or changed behavior has tests (parser changes **must** include parser tests)

## Checklist / 체크리스트

- [ ] One issue, one branch, one PR. The branch is named `<type>/<issue>-<slug>`.
- [ ] Docs updated (spec, catalog, ADR, CHANGELOG `Unreleased`) or not needed
- [ ] Screenshots (light and dark) attached for UI changes
- [ ] No secrets, tokens, private repository names, or personal paths (`/Users/<name>/…`)
- [ ] No new third-party dependency (or an accepted ADR is linked)
- [ ] Out-of-scope ideas were filed as `later` issues instead of being implemented here
- [ ] Every dependency is done and no `STAND-IN(#<issue>)` code is left (otherwise the PR stays a draft)

## Security impact / 보안 영향

<!-- Required when the PR has `area:security`, or touches Execution/, Git/, GitHub/, Parsing/, Security/, workflows, or hooks. -->

- [ ] No security impact, **or** the items below are checked
- [ ] Processes are created only in `Overgrove/Execution/`; arguments are arrays and user values come after `--`
- [ ] Commands use only allowlisted types (`ReadOnlyGitCommand` / `FetchCommand` / gh allowlist)
- [ ] The common safety `-c` flags and the environment allowlist still apply (docs/design/security-review.md)
- [ ] Untrusted output (git, gh, file names, refs) is parsed defensively and tested with hostile inputs
- [ ] Credentials are masked in UI, logs, and error messages
- [ ] Workflow changes: actions are pinned to a full commit SHA, `permissions:` are minimal, and untrusted inputs are passed through `env`
