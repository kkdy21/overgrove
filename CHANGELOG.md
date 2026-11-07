# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the major version is `0`, minor versions may contain breaking changes.

## [Unreleased]

## [0.1.0] - TBD

The first release: a read-only, macOS-native view of every Git worktree of a repository, with the commit graph,
changes, and GitHub issues in one window. Overgrove runs your system `git` against repositories it does not trust,
so the release also carries the hardening described in [docs/design/security-review.md](docs/design/security-review.md).

### Added

**Repositories and worktrees**

- Add a repository with the folder picker, switch between registered repositories, and manage the list; bare
  repositories that host linked worktrees can be added too (#220, #231).
- Worktree list with change counts, ahead/behind, locked and prunable states, and the `#n` issue a branch names
  (#225, #260).
- Worktree detail: path, branch, upstream, last fetch, and a security section that shows which repository settings
  were overridden or blocked for this worktree (#235).
- Parallel per-worktree queries with a concurrency limit, cancellation, debounced refresh, and an in-memory cache, so
  a ten-worktree repository opens in about 150 ms of git time on the reference machine (#221, #227, #246).

**Changes, commits, and diffs**

- Uncommitted changes of the focused worktree grouped as conflicted, staged, unstaged, and untracked, with per-file
  line counts (#229, #242).
- Commit graph across all worktrees with lane colors, ref pills, a WIP row above the focused worktree's HEAD, issue
  links, AI-assisted commit marks from `Co-authored-by` trailers, and paged loading (#251, #203, #260).
- Commit detail with message, parents, co-authors, and changed files (#258).
- Diff viewer for worktree changes, commits, stashes, and comparisons, with unified and split views and a confirmation
  before rendering very large diffs (#245, #258).
- Compare a worktree with its base branch as a pull-request-style list of commits ahead and files changed, with or
  without uncommitted changes (#238, #248).
- File history of a path across renames (#270).
- Local and remote branch lists, and the stash list with stash detail (#250, #252).
- Search over commits, authors, branches, and issue numbers (#283).

**GitHub and fetch**

- Issues panel for github.com remotes through the GitHub CLI (`gh`), linked to the worktrees, branches, and commits
  that mention each issue; the app keeps working without `gh` and explains how to set it up (#190, #257, #260, #265).
- Fetch per remote with progress, cancel, and timeout; failures are classified with guidance; last fetch time and
  ahead/behind refresh afterwards (#197, #200, #256).
- Optional automatic fetch, off by default (#272).

**App**

- Main window with toolbar, resizable and collapsible sidebar, graph, and detail panels, and a status bar (#216, #219).
- Onboarding that checks the git version and `gh` status; settings for automatic fetch and full remote URL display
  (#263, #268).
- Keyboard shortcuts (Jump to HEAD, panel focus, worktree info, copy full path), keyboard navigation in lists, and
  look-and-copy context menus: Copy SHA, Reveal in Finder, Open in Terminal, Open in Browser, and more (#269).
- VoiceOver labels and rotors, Increase Contrast support, and 20 pt hit targets (#276).
- Design system generated from design tokens, with an original panel theme, lane palette, and app icon (#214, #266).

**Project**

- Product, architecture, Git command catalog, parsing specification, threat model T1–T18, screen and interaction
  specs, design tokens, test strategy, performance budget, and QA process documents, with ADRs for each decision.
- Process execution through a `posix_spawn` runner with an explicit environment, timeouts, output limits, and
  cancellation (#138); parsers for every git and `gh` output the app reads, with adversarial input tests (#142,
  #181–#187, #192); a lane layout engine for the graph (#188).
- Tests: integration tests against a generated fixture repository, a canary harness for a malicious fixture,
  security tests for every threat, and opt-in performance tests against a 100,000-commit benchmark repository
  (#189, #196, #198, #202, #204, #206, #271).
- Contributor onboarding, issue claims, PR policy, project board automation, CI (build and test, secret scanning,
  dependency and workflow checks, test ID checks, CodeQL for workflows), Git hooks, and the Claude Code project
  harness; README in English and Korean.

### Security

Overgrove treats every repository as untrusted. Repository-controlled settings cannot run programs, change what the
app shows, or write to the repository through the app. Threat IDs refer to
[docs/design/security-review.md](docs/design/security-review.md); the
[security test pass report](docs/qa/reports/2026-11-08-security-test-pass.md) lists every SEC test and its result.

- Only allowlisted read-only git commands are built, with validated arguments and user or repository values after
  `--` or `--end-of-options`; process creation is confined to one module (T9, T13) (#147, #148).
- Common safety arguments disable fsmonitor, hooks, external diff, textconv, and signature programs for every command
  (T1–T3, T7) (#146).
- The environment is rebuilt from an allowlist; prompts for credentials are disabled (T10, T12) (#146).
- Repository-local filters, credential helpers, proxies, SSH commands, upload-pack, and similar settings are inspected
  before git runs and neutralized; settings that cannot be neutralized safely stop queries (T4–T6, T11) (#150).
- Only built-in transports are allowed; queries use no transport at all, so partial-clone settings cannot trigger
  lazy fetches that run remote commands (T5) (#191, #213, #217).
- Fetch uses a pinned refspec and prune scope, so repository settings cannot rewrite local refs (T13) (#210);
  `git diff` no longer rewrites the index (T13) (#211); fetches are capped at 16 remotes per repository (T15) (#261).
- Log output encoding is pinned, so repository i18n settings cannot shift `-z` fields and forge commit records
  (T15) (#207).
- Porcelain diff commands are hardened against submodule filters and repository diff settings (T3, T4) (#241).
- Each listed worktree is verified to belong to the repository and is inspected with its own settings before any
  command runs there; the number of queried worktrees is capped (T4, T14, T15) (#228, #249).
- Configuration inspection is linear in the size of the listing and bounded in what it keeps (T15) (#264).
- Credentials are masked in URLs, stderr, and logs, in linear time (T11, T16) (#140, #144); paths are validated for registration and
  symlink escapes (T14) (#141).
- Context menus only look and copy: Reveal in Finder stays inside the worktree, Open in Browser opens `https` only,
  copied text keeps control and bidi characters escaped, and Open in Terminal asks first unless the worktree's
  settings were checked and hold no finding (T14) (#269, #281).
- Supply chain and secret scanning: no third-party dependencies, GitHub Actions pinned by commit SHA with minimal
  permissions, and gitleaks in pre-commit, pre-push, and CI (T17, T18) (#201, #218).

### Known limitations

- Read-only by design: no commit, push, pull, checkout, stash apply/pop/drop, staging, or worktree removal in the
  app. Write operations are left to the terminal and AI agents (ADR-0011).
- GitHub issues work only for github.com remotes through `gh`, open issues only, up to 200. GitHub Enterprise and
  multiple accounts are not supported yet (#117).
- Fetch refuses partial clones on git older than 2.44, and in a partial clone, history views that need missing
  objects fail with a message instead of fetching them (T5).
- Remotes that need a custom remote helper (`codecommit::` and similar), `ftp://`, or a repository-chosen transport
  cannot be fetched (T5). Your own global `core.gitProxy` is ignored.
- No automatic refresh on file changes yet: Overgrove refreshes when the window becomes active, on `⌘R`, and after a
  fetch.
- A worktree whose index is stale (many files with only their modification time changed) can make status slow,
  because the app never writes the index (#168). Untracked files are listed up to 5,000 per worktree.
- In repositories without a commit-graph file, each graph page takes about 0.4 s of git time (#254).
- Submodule contents are not expanded; only the commit change of a submodule is shown.
- English UI only; fixed graph row height (no zoom); no multiple selection.
- Requires macOS 14 or later.

[Unreleased]: https://github.com/kkdy21/overgrove/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/kkdy21/overgrove/releases/tag/v0.1.0
