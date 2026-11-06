# Contributing to Overgrove

Thanks for your interest! Overgrove is a small, security-sensitive project, so we work in a deliberate,
**issue-first** way. This page is the short version; the detailed process docs live in
[`docs/process/`](docs/process/) (written in Korean — feel free to ask questions in English).

> 한국어 안내: 이슈·PR·Discussion은 한국어와 영어 모두 환영합니다. 제목만 영어(Conventional 형식)로 써 주세요.

## Ground rules

1. **No issue, no PR.** Every pull request must close an issue (`Closes #123`). Small fixes are welcome too — open a quick
   `chore` or `bug` issue first.
2. **Claim before you code.** Comment `/claim` on the issue and open a (draft) PR within 5 hours — see below.
3. **Discuss before you design.** Ideas and open questions start in [Discussions](https://github.com/kkdy21/overgrove/discussions).
   When something is agreed, it becomes an issue.
4. **Security problems are never public.** Report them privately — see [SECURITY.md](SECURITY.md).
5. **Stay in scope.** v0.1 is read-only (plus `git fetch`). Write operations such as push, pull, reset, staging, and rebase are
   out of scope. Proposals for them are welcome as `later` issues.
6. Be kind. We follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Workflow at a glance

```
Discussion (optional) → Issue (triaged) → /claim → Fork branch → Draft PR (≤ 5h) → Commits → Ready PR → Review → Squash merge → Issue closes
```

### 1. Pick an issue and claim it

Work happens in your **fork**; you do not need any role on this repository.

1. Find an issue that is open, unassigned, not an epic, not labeled `status:blocked` / `status:needs-decision` /
   `status:triage`. Issues whose dependencies are already done are the easiest start, but you do not have to wait for
   dependencies (see below). Good starting points:
   [`good first issue`](https://github.com/kkdy21/overgrove/labels/good%20first%20issue),
   [`help wanted`](https://github.com/kkdy21/overgrove/labels/help%20wanted), and the current phase on the
   [project board](https://github.com/users/kkdy21/projects/4).
2. Comment **`/claim`** on the issue. A bot assigns you and posts a deadline.
3. **Open a pull request (a draft is fine) with `Closes #<issue>` within 5 hours**, or the claim is released
   automatically. Once your PR is open, the claim stays while the PR is open.
4. Comment **`/unclaim`** if you stop, so someone else can take it.

| Rule | Value |
|---|---|
| Claim lease | 5 hours to open a PR (draft OK) |
| Open claims per person | 2 |
| Unassigned issue | The first open PR wins; later PRs fail the `pr-policy` check |
| A PR counts only if | it is open, says `Closes #<issue>`, comes from a `<type>/<issue>-<slug>` branch, and was updated in the last 72 hours |
| Re-claim after expiry | Not for 24 hours on the same issue |
| Someone else's claimed issue | Your PR fails the `pr-policy` check |
| Unfinished dependency | Claim anyway and build a stand-in; your PR passes `pr-policy` only after the dependency is done |

Details and rationale: [docs/process/collaboration.md](docs/process/collaboration.md) (Korean),
[ADR-0013](docs/adr/0013-external-contributions-and-issue-claiming.md), and
[ADR-0014](docs/adr/0014-dependent-issues-stand-in.md).

#### When your issue depends on unfinished work

You do not have to wait for another issue to be merged.

1. **Build what you need yourself.** Write only the part of the dependency that your issue uses, as a *stand-in*, and
   mark each block with a `STAND-IN(#<issue>)` comment. Use the names from the dependency's spec so the switch is small.
2. **Do not merge or check out someone else's unmerged PR.** Its Git hooks, `.claude/` hooks, and tests would run on
   your machine. If it has a PR, read the diff (`gh pr diff`) to match names, nothing more.
3. **Your PR closes only your issue and stays a draft.** If the dependency is not already listed under `## 의존성` in
   your issue, add a `Depends on #<issue>` line to the PR body.

`pr-policy` fails while a dependency is open or a stand-in is left, so nothing merges out of order. When the dependency
closes, a bot comments on your PR: merge `upstream/main`, replace the stand-ins with the real code, run the tests, and
mark the PR ready. If nobody has claimed the dependency, you may claim it as well and build your issue on top of your own
branch. Rejected, abandoned, and closed-as-not-planned dependencies are covered in
[collaboration.md §4.1](docs/process/collaboration.md#41-의존-이슈가-아직-끝나지-않았을-때) (Korean).

Found something new? Open an issue with a template first (**Feature**, **Bug**, **Spike**, **Decision**, **Docs**, or
**Chore**). The maintainer triages it before it can be claimed.

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

- Only the maintainer merges, and every contributor PR is reviewed first: it needs an approving review from the maintainer's account. Reviews may be AI-assisted (the `/pr-review` workflow), but the maintainer makes the call.
- **No rebasing or force-pushing needed.** If `main` moves ahead, use the "Update branch" button or `gh pr update-branch <n>` (or merge `upstream/main`). Squash merge keeps `main` linear anyway.
- Keep "Allow edits by maintainers" enabled so the maintainer can update your branch.
- Your **first** PR needs a maintainer to approve the workflow run before checks start; later PRs run automatically.

- CI must pass: `gitleaks` (secret scan), `pr-policy` (title/body/branch rules), `build-test` (build and tests).
- We merge with **squash merge** only. The branch is deleted after merge.
- Review comments follow [Conventional Comments](https://conventionalcomments.org/) labels
  (`suggestion:`, `issue:`, `question:`, `nitpick:`, `praise:`) so the intent is clear.

## Development setup

Requirements: macOS 14 or later, Xcode 26 or later, `git` 2.36 or later, and [gitleaks](https://github.com/gitleaks/gitleaks)
for the local secret-scan hooks. `gh` is optional (only needed for the GitHub issues panel and for maintainer scripts).

```sh
gh repo fork kkdy21/overgrove --clone --remote   # origin = your fork, upstream = kkdy21/overgrove
cd overgrove
./scripts/bootstrap.sh                           # installs Git hooks (core.hooksPath=.githooks) and checks your toolchain
```

### Quick start with Claude Code

The project harness (`CLAUDE.md`, `.claude/` skills, agents, and hooks) is committed, so Claude Code follows the same
rules for every contributor. After the setup above:

```sh
claude
> 백로그 확인해서 진행해줘        # or: "check the backlog and work on it"
```

That one sentence runs the whole flow (`/onboard`):
1. Setup checks: gh login, fork remotes, hooks, Xcode.
2. A short list of claimable issues; you pick one.
3. `/claim`, a branch, and a test-first implementation.
4. A draft PR right after the first commit, to keep the claim.
5. Lint, tests, and security checks; the PR is marked ready.

Claude stops to ask when it needs a decision, a login, or `sudo`. It never merges. You can also run the steps yourself:

```text
> /onboard          # setup + pick + claim + start
> /pr-open --draft  # right after your first meaningful commit
> /pr-open          # when the acceptance criteria are met (or mark the draft ready)
```

### Build and test

Open `Overgrove.xcodeproj` and press ⌘U to run the tests (⌘R opens a placeholder window for now). CI runs the same
tests with:

```sh
xcodebuild test -project Overgrove.xcodeproj -scheme Overgrove -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
```

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
- `README.md` is the source of truth. If you change it, say so in the PR; the maintainer keeps the Korean translation
  (`README.ko.md`) in sync.

## Using AI coding assistants

AI-assisted contributions are welcome. The maintainer develops and reviews with Claude Code, and the project harness
(`CLAUDE.md`, `.claude/`) encodes the same rules as this file.

- **You are responsible for every line you submit**: read it, test it locally, and be able to explain it.
- Say so in the PR body when a large part was generated (`AI-assisted: <tool>`). `Co-Authored-By` trailers are fine.
- Do not disable or bypass the repository hooks or rules (`--no-verify`, changing `core.hooksPath`, and so on).
- One issue, one PR. If the assistant wanders out of scope, drop those changes and suggest a `later` issue instead.
- Do not run several agents on the same issue and open several PRs. Experiment in your fork, submit one PR.

## Licensing

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
