# Contributing to Overgrove

Thanks for your interest! Overgrove is a small, security-sensitive project, so we work in a deliberate,
**issue-first** way. This page is the short version; the detailed process docs live in
[`docs/process/`](docs/process/) (written in Korean — feel free to ask questions in English).

> 한국어 안내: 이슈·PR·Discussion은 한국어와 영어 모두 환영합니다. 제목만 영어(Conventional 형식)로 써 주세요.

## Ground rules

1. **No issue, no PR.** Every pull request must close an issue (`Closes #123`). Small fixes are welcome too — open a quick
   `chore` or `bug` issue first.
2. **Discuss before you design.** Ideas and open questions start in [Discussions](https://github.com/kkdy21/overgrove/discussions).
   When something is agreed, it becomes an issue.
3. **Security problems are never public.** Report them privately — see [SECURITY.md](SECURITY.md).
4. **Stay in scope.** v0.1 is read-only (plus `git fetch`). Write operations such as push, pull, reset, staging, and rebase are
   out of scope. Proposals for them are welcome as `later` issues.
5. Be kind. We follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Workflow at a glance

```
Discussion (optional) → Issue (triaged, labeled) → Branch → Commits → Pull request → Review → Squash merge → Issue closes
```

### 1. Pick or open an issue

- Use an issue template: **Feature**, **Bug**, **Spike**, **Decision**, **Docs**, or **Chore**.
- Look for [`good first issue`](https://github.com/kkdy21/overgrove/labels/good%20first%20issue) and
  [`help wanted`](https://github.com/kkdy21/overgrove/labels/help%20wanted).
- Comment on the issue before starting so work is not duplicated. The maintainer will assign it.

### 2. Branch

```
<type>/<issue-number>-<short-slug>
```

`type` is one of `feat`, `fix`, `docs`, `test`, `chore`, `spike`, `refactor`, `perf`, `ci`.
Example: `feat/12-worktree-list`.

### 3. Commit

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(parser): parse porcelain v2 rename records

Refs #12
```

- Allowed types: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `chore`, `ci`, `build`, `style`, `revert`.
- The repository's Git hooks add `Refs #<n>` automatically from your branch name and check the header format.

### 4. Open a pull request

- **Title**: Conventional Commits format, in English. It becomes the squash-commit title on `main`.
- **Body**: fill in the template. It must contain `Closes #<n>`.
- Keep PRs focused: one issue, one branch, one PR.
- Parser changes must include tests. Security-relevant changes must include the `area:security` label and the security checklist.

### 5. Review and merge

- CI must pass: `gitleaks` (secret scan), `pr-policy` (title/body/branch rules), `build-test` (build and tests).
- We merge with **squash merge** only. The branch is deleted after merge.
- Review comments follow [Conventional Comments](https://conventionalcomments.org/) labels
  (`suggestion:`, `issue:`, `question:`, `nitpick:`, `praise:`) so the intent is clear.

## Development setup

Requirements: macOS 14 or later, a recent Xcode, `git` 2.36 or later, and [gitleaks](https://github.com/gitleaks/gitleaks)
for the local secret-scan hooks. `gh` is optional (only needed for the GitHub issues panel and for maintainer scripts).

```sh
git clone https://github.com/kkdy21/overgrove.git
cd overgrove
./scripts/bootstrap.sh     # installs Git hooks (core.hooksPath=.githooks) and checks your toolchain
```

> The Xcode project is created in Phase 3. Until then the repository contains planning, design, and tooling only.

### Formatting

We use the `swift format` tool that ships with the Swift toolchain (no third-party linters).

```sh
swift format --in-place --recursive --configuration .swift-format Overgrove OvergroveTests
swift format lint --strict --recursive --configuration .swift-format Overgrove OvergroveTests
```

### Rules that CI and reviewers enforce

- No third-party dependencies (Swift packages, CocoaPods, binaries) without an accepted ADR.
- Only `Overgrove/Execution/` may create processes (`Process`, `NSTask`, `posix_spawn`, `system`).
- Git commands are built from the allowlisted command types. Never build command lines from strings, and never use a shell.
- No secrets, tokens, or personal paths (`/Users/<name>/…`) in commits, issues, or PRs. Hooks and CI run gitleaks.

## Using AI coding assistants

The maintainer develops with Claude Code. The project-level harness (`CLAUDE.md`, `.claude/`) is part of the repo and
documents the same rules as this file. If you use an AI assistant, you are still responsible for every line you submit:
read it, test it, and make sure it follows the rules above.

## Licensing

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
