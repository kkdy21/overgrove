<p align="center">
  <img src="design/icon/app-icon.svg" width="128" height="128" alt="Overgrove app icon">
</p>

<h1 align="center">Overgrove</h1>

<p align="center">
  A native macOS Git client for people who work in many <code>git worktree</code>s at once.<br>
  See every worktree, its uncommitted changes, stashes, and how far it is from its remote, all in one window.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="Platform: macOS 14+" src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg">
  <img alt="Status: pre-alpha" src="https://img.shields.io/badge/status-pre--alpha-orange.svg">
</p>

<p align="center">
  <strong>English</strong> | <a href="README.ko.md">한국어</a>
</p>

---

> **Status: pre-alpha, not usable yet.** The foundation that runs `git` safely is implemented and tested: process
> execution, hardened git invocation, repository config inspection, credential masking, and path validation. Parsers
> are in progress, and the app window is still a placeholder. The first round of screen mockups is below; a redesign
> is in progress in [#166](https://github.com/kkdy21/overgrove/issues/166). Follow the [roadmap](docs/roadmap.md)
> and the [v0.1.0 milestone](https://github.com/kkdy21/overgrove/milestone/1).

## Why

If you develop several features in parallel with `git worktree`, it is hard to answer simple questions quickly:

- Which worktree has uncommitted work, and is it staged?
- What is sitting in the stash, and which branch did it come from?
- How far ahead or behind its upstream is each branch?
- Who changed what, and when?

Overgrove answers those questions on one screen, without mixing in write operations.

## Who is it for

Overgrove is for developers who keep several worktrees going at once, often with an AI coding agent working in each,
and want one calm window that answers *"what is going on where?"*

It is a good fit if:

- **Your Git GUI slows your Mac down.** Clients that keep file watchers running on every repository can use a lot of
  CPU and memory once you have many worktrees open. Overgrove v0.1 has no always-on file watcher: it refreshes when the
  window becomes active, when you press ⌘R, and after a fetch.
- **A tool you relied on stopped getting updates.** Overgrove is MIT-licensed, has zero third-party dependencies, and
  builds from source with Xcode alone, so it is easy to keep alive.
- **Your current client cannot show your worktrees side by side.** Worktrees are the primary object here: each one with
  its branch, uncommitted changes, and ahead/behind status, plus the repository's stashes, all in one sidebar.
- **You don't want to pay a subscription for a read-only overview.** Free and open source. No account, no telemetry.
- **You are tired of hopping between terminal tabs to run `git status`.** One window replaces the round of `cd` and
  `git status`, and you keep using the CLI for the actual writes.
- **You run AI agents in parallel worktrees** and need to see what each one changed before you review or merge.

It is probably not for you yet if:

- you want to stage, commit, push, pull, or rebase from a GUI. Overgrove stays read-only plus `git fetch`; commits,
  pushes, and cleanup are left to your terminal or your AI agents.
- you need Windows or Linux.
- you want a signed, notarized download. Overgrove is source-only for now.

## Screenshots

> **Design mockups — the app is in development.** These images are drawn from the design tokens with sample data;
> they are not screenshots of a running build. More screens are in [docs/design/mockups.md](docs/design/mockups.md).

| Light | Dark |
|---|---|
| ![Overgrove main window mockup, light appearance](design/mockups/main-window-light.png) | ![Overgrove main window mockup, dark appearance](design/mockups/main-window-dark.png) |

## Planned features (v0.1.0)

- **Worktrees:** every worktree with its branch, HEAD, path, and locked or prunable state
- **Working state per worktree:** staged, unstaged, untracked, and conflicted files
- **Changes against the base branch:** a PR-style view of what a worktree changed since it branched off `main`
  (commits ahead, changed files, untracked files), so you can review an agent's work before opening the pull request
- **Stashes:** the repository's stash list with a per-stash change summary
- **Ahead/behind:** compared with each branch's upstream after `git fetch`, with the last fetch time
- **Commit graph:** author, date, and message, with a *WIP* row on top for uncommitted changes; commits co-authored by
  an AI agent (`Co-authored-by` trailer) are marked
- **Commit details and file history**
- **GitHub issues (optional):** listed through your existing `gh` login and linked to branches by issue number

**Read-only by design.** The only operation that touches a remote is `git fetch`. Push, pull, merge, reset, and staging
are intentionally left out: Overgrove sits next to your terminal or AI agents, which do the writing
([scope](docs/scope-mvp.md)).

## Security

Opening an untrusted repository in a Git client can run code that the repository configures. Overgrove takes a
defensive approach:

- `git` is invoked with argument arrays, never through a shell
- dangerous repository settings (fsmonitor, hooks, filters, external diff, credential helpers, custom SSH commands, …)
  are forced off
- a repository cannot route `git fetch` through its own proxy or TLS certificates
- the child environment is built from an allowlist
- every command has a timeout and an output limit
- credentials in remote URLs are masked
- tokens are never stored: GitHub access goes through `gh`

Read [SECURITY.md](SECURITY.md) for details and for how to report a vulnerability privately.

## Requirements

- macOS 14 Sonoma or later
- Xcode 26 or later to build from source
- Git 2.36 or later. Overgrove runs Apple's `git` from the developer directory selected with `xcode-select` (Xcode or
  the Command Line Tools)
- Optional: [GitHub CLI](https://cli.github.com/) (`gh`), logged in, for the issues panel

## Build from source

Overgrove is distributed **as source only**. No signed or notarized binaries are provided.

```sh
git clone https://github.com/kkdy21/overgrove.git
cd overgrove
./scripts/bootstrap.sh     # installs the Git hooks and checks your toolchain
open Overgrove.xcodeproj   # ⌘U runs the tests; ⌘R opens a placeholder window for now
```

## How we work

Every change starts as an issue and reaches `main` only through a pull request that passes the same safety net
locally, in CI, and in the branch ruleset. Planning documents move through phase gates that the maintainer approves.

```mermaid
flowchart TB
    subgraph plan["1 · Plan"]
        direction LR
        DIS["Discussion<br/>ideas · design"] -->|agreed| ISS["Issue<br/>template · labels · milestone"]
        ISS --> BRD["Projects board<br/>Backlog → Ready"]
        ISS -.->|needs a decision| ADR["Decision issue<br/>→ ADR"]
    end

    subgraph build["2 · Build (local)"]
        direction LR
        BR["Branch or worktree<br/>type/issue-slug"] --> CC["Claude Code harness<br/>skills · agents · guard hooks"]
        CC --> GH["Git hooks<br/>gitleaks · commit format<br/>forbidden APIs"]
    end

    subgraph verify["3 · Verify (GitHub)"]
        direction LR
        PR["Pull request<br/>Closes #n"] --> CK[["Required checks<br/>gitleaks · pr-policy · build-test"]]
        CK --> RV["Review<br/>threads resolved"]
    end

    subgraph ship["4 · Merge"]
        direction LR
        RS["main ruleset<br/>squash only · no bypass"] --> SQ["Squash merge"]
        SQ --> DONE["Issue closed<br/>board Done"]
    end

    plan -->|start work| build
    build -->|git push| verify
    verify --> ship
    ship -.->|phase complete| GATE(["Phase gate<br/>maintainer approval"])
```

| Layer | Enforced by | Details |
|---|---|---|
| Issue first | `pr-policy` check, templates | [Issues](docs/process/issues.md) |
| Claim before code (5h to open a draft PR, first PR wins) | `/claim` bot, `claim-expiry` workflow, `pr-policy` check | [Collaboration](docs/process/collaboration.md) |
| Secrets and personal paths | Git hooks, Claude Code hook, `gitleaks` check, GitHub push protection | [Branching and commits](docs/process/branching-and-commits.md) |
| Process and shell APIs only in `Overgrove/Execution/` | Git hook, Claude Code hook, `build-test` check | [Security review](docs/design/security-review.md) |
| Review and merge | `main` ruleset (squash only, required checks, resolved threads) | [Pull requests](docs/process/pull-requests.md) |
| Phase approval | Maintainer, `/phase-gate` report | [Phase gates](docs/process/phase-gates.md) |

The full flow is described in [docs/process/development-workflow.md](docs/process/development-workflow.md), and the
Claude Code harness in [docs/process/claude-code-harness.md](docs/process/claude-code-harness.md).

## Project documents

| | |
|---|---|
| Product | [PRD](docs/prd.md) · [MVP scope](docs/scope-mvp.md) · [Glossary](docs/glossary.md) · [Roadmap](docs/roadmap.md) |
| Design | [Art direction](docs/design/art-direction.md) · [Information architecture](docs/design/information-architecture.md) · [Screens](docs/design/screens.md) · [Interaction](docs/design/interaction.md) · [Design tokens](docs/design/design-tokens.md) · [Iconography](docs/design/iconography.md) |
| Engineering | [Architecture](docs/architecture/overview.md) · [Git command catalog](docs/architecture/git-command-catalog.md) · [Parsing spec](docs/architecture/parsing-spec.md) · [ADRs](docs/adr/) |
| Security | [Security review & threat model](docs/design/security-review.md) · [SECURITY.md](SECURITY.md) |
| Quality | [Test strategy](docs/testing/test-strategy.md) · [Performance budget](docs/performance/performance-budget.md) · [QA process](docs/qa/process.md) |
| Process | [Contributing](CONTRIBUTING.md) · [Development workflow](docs/process/development-workflow.md) · [Code of Conduct](CODE_OF_CONDUCT.md) |

Internal planning and design documents are written in Korean; contributor-facing documents are in English
([ADR-0005](docs/adr/0005-documentation-language.md)). This README is also available in [Korean](README.ko.md).

## Contributing

Issues, ideas, and pull requests are welcome, including AI-assisted ones. Start with [CONTRIBUTING.md](CONTRIBUTING.md).
The short version: comment `/claim` on an issue and open a draft PR within 5 hours, every PR closes an issue, ideas start in [Discussions](https://github.com/kkdy21/overgrove/discussions), and security
reports go through [private reporting](https://github.com/kkdy21/overgrove/security/advisories/new).

## Acknowledgements

The three-pane layout (sidebar, commit graph, detail) follows a common pattern among Git clients. Overgrove does not
use any other product's name, logo, icons, wording, or color palette.

## License

[MIT](LICENSE)
