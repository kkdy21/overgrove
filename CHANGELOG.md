# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the major version is `0`, minor versions may contain breaking changes.

## [Unreleased]

## [0.1.0] - YYYY-MM-DD

The first release. Overgrove is a read-only Mac app that shows every worktree of a repository in one window: what
each one has changed, how far it is from its upstream, the stashes, and the commit graph. The only operation that
touches a remote is `git fetch`. It is distributed as source only: build it with Xcode 26 or later, and run it on
macOS 14 or later.

### Added

**Repositories and worktrees**

- Add repositories with the folder picker (⌘O), switch between them in the toolbar, and manage the list in
  Settings. Bare repositories that host linked worktrees can be added too.
- A sidebar that lists every worktree with its branch or detached HEAD, path, change counts, ahead/behind, locked
  and prunable state, the issue its branch names, and its pull request.
- Worktree detail with the branch, upstream, last fetch, and a Security card that lists the repository settings
  Overgrove turned off or that stopped a query. The card can copy a report with credentials masked.
- On relaunch, the last worktree list is drawn at once from a small on-disk snapshot while the first real load
  runs.

**Changes and diffs**

- The focused worktree's uncommitted changes, grouped as conflicted, staged, unstaged, and untracked, with line
  counts per file, and a Submodules card that shows each submodule's own state.
- A diff viewer for worktree changes, commits, stashes, and comparisons: unified or split, changed words
  highlighted, whitespace shown on request, and a confirmation before a very large diff is drawn.
- Compare with base: a pull-request-style view of the commits a worktree adds on top of its base branch and the
  files it changed, with or without uncommitted changes. A card at the bottom of the worktree detail sums it up.
- Compare any two commits, with the files and the commits between them.
- When `git status` is slow because the index is stale, the status bar says why and how to make it fast again.

**Commit graph and history**

- A commit graph with lane colors, pills for branches, tags, and worktrees, stash nodes, a WIP row for the focused
  worktree, and an AI mark on commits that carry an AI agent's `Co-authored-by` trailer. Pages load as you scroll,
  and repositories without a commit-graph file are streamed.
- Search the loaded graph by message, author, SHA, ref name, or `#issue`; filter by author; resize and hide
  columns; zoom with ⌘+ and ⌘−.
- Commit detail with the message, parents, co-authors, and changed files.
- File history that follows renames, with a switch to turn that off.

**Branches, tags, and stashes**

- Local and remote branch trees with upstream status, a Tags section, and the stash list. Choosing a branch or tag
  selects its commit in the graph; a stash shows its files and how each one changed.

**Fetch and refresh**

- Fetch per remote with progress, cancel, and a timeout. Failures are explained with what to do next. The status
  bar shows the last fetch time, and ahead/behind is updated afterwards.
- Optional automatic fetch, off by default.
- Automatic refresh while the window is visible: Overgrove watches the worktrees for file changes and re-reads only
  the ones that changed. A covered or minimized window stops watching and catches up when it is shown again.

**Issues and pull requests**

- An issues panel that reads open issues through a command-line tool you are already logged in to: `gh` for
  github.com and GitHub Enterprise hosts, `glab` for GitLab, and `gt` for Gitea. Issues are linked to the branches,
  worktrees, and commits that mention their number. Without a login, the panel shows the command to run.
- Pull request status from GitHub on worktree and branch rows, and a Pull request card in the worktree detail. A
  pull request is attached only when its head repository and branch match the branch's upstream, so a fork's
  branch with the same name never shows up.
- The active `gh` account for the repository's host, in the status bar and the issues panel.

**Working with other apps**

- Open a worktree or a file in the terminal or editor you choose in Settings.
- Open commits, branches, and files on GitHub. A branch opens in the repository of the remote it tracks.
- Quick Look for working tree files on macOS 15 and later.
- Context menus to copy SHAs, messages, and paths, and to reveal files in Finder.

**App**

- A three-panel window (sidebar, graph, detail) with resizable and collapsible panels, a toolbar, and a status
  bar, in light and dark appearances.
- A setup assistant that checks `git` and the `gh` login, and Settings for automatic fetch, remote URL display, the
  repository list, the `git` executable, and the terminal and editor.
- Choose another `git`, such as Homebrew's, in Settings › Advanced. It is checked for ownership, permissions, and
  version (2.36 or later) when chosen and at every launch.
- Keyboard use throughout: the sidebar is one Tab stop and the arrow keys move across all its sections, there are
  shortcuts for the panels and common actions, and you can go back and forward through selections.
- VoiceOver labels and rotors, Increase Contrast, and Reduce Motion support.
- English and Korean, following the system language.

**Project**

- An Xcode project with no third-party dependencies that signs the app to run locally, so no Apple Developer
  account is needed. `scripts/bootstrap.sh --build` checks that a Mac can build it and changes nothing; the default
  mode also installs the contributor Git hooks.
- Product, design, architecture, threat model (T1–T19), testing, performance, and process documents, with an ADR
  for each decision. The README is in English and Korean.
- CI that builds and tests every pull request, scans for secrets, checks the PR policy, workflows, and
  dependencies, runs CodeQL, and runs a scheduled git compatibility matrix. Bots handle issue claims and keep the
  project board up to date.

### Security

Overgrove assumes every repository it opens is untrusted. Settings a repository controls cannot run programs, send
your credentials elsewhere, or write to the repository through the app. Threat IDs refer to the
[security review](docs/design/security-review.md), which also lists the tests behind each item.

- Processes are started from one module only, with argument arrays and never a shell. Only allowlisted read-only
  git commands and `git fetch` exist in the code. Values from the user or the repository go after `--`, and refs
  that start with `-` are refused (T9, T13).
- Every git command turns off fsmonitor, hooks (including hooks defined in config), external diff and textconv,
  signature programs, automatic gc and maintenance, the pager, and optional index locks (T1–T3, T7, T8).
- Before git runs, the repository's own config is inspected. Filters, credential helpers, SSH and proxy commands,
  `uploadpack`, proxies, proxy authentication, cookie files, and similar settings are overridden for Overgrove's
  commands and listed in the Security card. A setting that cannot be overridden safely stops the query. Fetch is
  refused when a repository sets its own TLS certificates or fixed host addresses (T4–T6, T11).
- The child environment is built from an allowlist instead of being inherited, credential prompts are turned off,
  and every command has a timeout and an output limit (T10, T12, T15).
- Queries use no transport at all, so partial-clone settings cannot start a lazy fetch. Fetch allows only Git's
  built-in transports, and remotes that would need a custom remote helper are refused before git runs (T5).
- Fetch uses its own refspecs and turns off tag pruning and bundle URIs, so repository settings cannot rewrite local
  refs. Showing a diff never rewrites the index (T13).
- The log output encoding is fixed, so repository settings cannot shift fields and forge commit records (T15).
- Each listed worktree is checked to belong to the repository and inspected with its own settings. At most 64
  worktrees are queried and 16 remotes fetched per repository. Submodules are inspected with their own settings
  before their state is read (T4, T14, T15).
- Credentials are masked in remote URLs, git's error output, logs, and copied reports (T11, T16). Paths are
  validated before any file is read, and symbolic links cannot lead out of the worktree (T14).
- Open in Terminal and Open in Editor ask first unless the worktree's settings were checked and hold no finding and
  no hook, because a shell or an editor does use the repository's settings (T14). Quick Look refuses file types
  whose preview renders web content.
- Untrusted repository mode: a repository marked untrusted never fetches from remotes that are folders on this Mac,
  since fetching one runs git in that other repository, and it always asks before opening a terminal or editor
  (T5, T14).
- `gh`, `glab`, and `gt` run only a fixed set of commands in a hardened environment, and a host is used only when
  its tool reports a working login there. Overgrove never reads or stores tokens (T11).
- The launch snapshot keeps only display values (no remote URLs, config values, file names, or commit contents),
  is read as untrusted input, and is never used for a security decision (T19).
- No third-party dependencies, GitHub Actions pinned to commit SHAs with minimal permissions, and gitleaks in the Git
  hooks and CI (T17, T18).

### Known limitations

- Read-only by design: no staging, commit, push, pull, merge, rebase, checkout, stash apply or drop, or worktree
  removal. The terminal and your AI agents do the writing ([ADR-0011](docs/adr/0011-no-pull-in-v0-1.md),
  [ADR-0021](docs/adr/0021-read-only-scope-after-v0-1.md)).
- Repository filters are turned off, so files that a filter such as Git LFS rewrites can show as changed. The
  Security card says when this applies.
- The issues panel shows open issues only: up to 200 from GitHub or Gitea and 50 from GitLab. Pull request status is
  GitHub only. Forgejo is not supported.
- On git older than 2.45.1, fetch is refused for partial clones and for remotes that are folders on this Mac. In a
  partial clone, views that need missing objects show an error instead of downloading them.
- Remotes that need a custom remote helper (`codecommit::` and the like) or `ftp://` cannot be fetched. Shell proxy
  variables such as `HTTPS_PROXY` are not passed to git; set `http.proxy` in your global config instead
  ([guide](docs/guides/self-hosted-git.md)).
- Search covers only the graph pages that are loaded. Untracked files are listed up to 5,000 per worktree.
- When many files have changed only their modification time, `git status` can be slow, because Overgrove never
  writes the index. Running `git status` once in Terminal, in a repository you trust, fixes it.
- No multiple selection of commits or files.

[Unreleased]: https://github.com/kkdy21/overgrove/commits/main
[0.1.0]: https://github.com/kkdy21/overgrove/releases/tag/v0.1.0
