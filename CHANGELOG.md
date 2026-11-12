# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the major version is `0`, minor versions may contain breaking changes.

## [Unreleased]

### Added

- Issue panel: GitLab issues through `glab` for a repository without a GitHub remote, read only after glab reports the
  remote's host logged in (ADR-0026). A remote on a host no CLI is logged in to shows "Not logged in to HOST" with the
  gh and glab login commands to copy.

- Project bootstrap: product requirements, MVP scope, glossary, roadmap, and architecture decision records.
- Architecture, Git command catalog, parsing specification, and security review (threat model T1–T18).
- Information architecture, screen specs, interaction design, design tokens, and app icon.
- Test strategy, fixture and benchmark repository generators, performance budget, and QA process.
- Contributor docs, issue/PR/discussion templates, labels, CI workflows (secret scan, PR policy, build, CodeQL),
  Git hooks, and the Claude Code project harness.
- README: development process diagram ("How we work") and a table of which control enforces each rule.
- README: "Who is it for" section describing the problems Overgrove targets and when it is not a fit yet.
- App skeleton: Xcode project (macOS 14+, Swift 6 with complete strict concurrency) and a CI job that builds and runs the tests.
- Process execution: a `posix_spawn`-based runner with an explicit environment, timeouts, output limits, process-group
  termination, and cancellation.
- Hardened git invocation: allowlisted read-only commands, validated arguments (object IDs, full ref names, paths),
  common safety flags, an environment allowlist, and a classified error model.
- Repository config inspection: repository-local filters, credential helpers, proxies, and SSH commands are neutralized
  before git runs, and fetch is blocked when a repository sets its own TLS certificates.
- Credential masking for URLs, stderr, and logs; path validation for registration and symlink escapes.
- Value models and parsers for `git config`, `git version`, and `gh` JSON output.
- Korean README (`README.ko.md`) with an English/Korean switcher at the top of both files.
- Pull request status (ADR-0023): worktree and local branch rows show the linked PR's state and number, and the
  worktree detail shows a Pull request card. A PR is linked only when its head owner, repository, and branch match the
  branch's upstream, so a same-named branch from a fork never attaches.
- Commit comparison (S-12): a COMMITS section lists the commits the target has that the base does not, newest first
  (up to 500), and each row opens that commit.
- Korean localization, first part: Settings, the setup assistant, the graph header and columns, the diff viewer, and
  the menu commands follow the system language through a String Catalog. Git names, commands, and copied values stay
  as they are.
- Open on GitHub for branches opens the repository of the remote each branch tracks, so in a fork flow a branch
  tracking your fork opens the fork.

### Changed

- Open on GitHub for a remote-tracking branch uses the remote its row is grouped under: a branch of a non-GitHub
  remote whose name starts with a GitHub remote's name no longer opens the GitHub remote's page.
- GitHub hosts are trusted only when gh has a working login there, not just any account entry.
- The setup assistant counts a gh login on any host, as the status bar does: a login only on a GitHub Enterprise host
  shows as set up and names the host.
- Graph Zoom In also answers ⌘= on keyboards where + needs Shift.
- Quick Look refuses more file types whose preview renders web content or names a location, by extension and by
  file type.
- Open on GitHub for commits and files uses only the remotes the current load inspected, like branch rows.
- Auto fetch catches up a repository newly opened in a window when the window becomes active, instead of waiting out
  the previous repository's interval.
- The repository switcher shows the remote owner next to the name: the GitHub or Gitea owner, or GitLab namespace, of
  the repository whose issues the panel reads.
- Check Again and ⌘R on a "Not logged in to HOST" issue panel read gh's login list again, so a `gh auth login` or a gh
  install since the last check shows the host's issues without restarting the app. Auto refresh still does not run gh.
- Enterprise Managed User logins and owners (`handle_shortcode`) are accepted on GitHub. A github.com login gh reports
  that the app cannot read no longer drops the other hosts gh is logged in to.
- A remote on GitHub's SSH-over-443 endpoint (`ssh://git@ssh.github.com:443/OWNER/NAME`) is read as github.com, so
  its issues and pull requests show instead of "Not logged in to ssh.github.com".
- Check Again in the setup assistant also updates the status bar's gh field, the gh accounts, and the trusted GitHub
  hosts, so issue panels follow a `gh auth login` without another check.
- Remote-tracking branches of a remote whose name Overgrove does not pass to git (one with `+`, `@`, or non-ASCII
  from a hand-edited config) stay under their own remote, instead of being grouped under, and opening on GitHub as, a
  GitHub remote whose name is a prefix of theirs.
- Open on GitHub for a remote-tracking branch follows the remote's fetch refspecs: a ref fetched from somewhere other
  than a branch (such as `origin/pr/123` from `refs/pull/123/head`) no longer opens a `tree/` page.
- Open in Terminal and Open in Editor ask first while the worktree list is still drawn from the in-memory cache: the
  cached settings check is the previous load's. This load's check decides once it arrives.
- Open on GitHub and pull request links for a local branch match its upstream remote's name byte for byte, so a
  hand-edited name that only looks like a GitHub remote's (KELVIN SIGN for `K`, or NFD for NFC) no longer reaches it.
- Two local branches whose names differ only in Unicode normalization each show their own pull request, and two
  remote names that differ only that way both go without GitHub links instead of one taking the other's place.
- A tag of a tree or a file says so in TAGS instead of showing as a commit, and choosing it no longer clears the
  graph selection while the detail panel keeps the old commit.

- `scripts/bootstrap.sh`: `--build` checks only what building needs (macOS, Xcode readiness, the git that xcrun
  finds) and changes nothing; the default contributor mode says it will set `core.hooksPath` before doing so, and
  each problem comes with the command that fixes it.
- Process: the project board follows issues, pull requests, and claims automatically (`board-sync`, ADR-0016), and
  running several maintainer sessions in parallel has explicit rules (separate worktrees, assign before starting).

- Design: the main window uses its own panel theme — three rounded, resizable, independently scrolling panels with
  grab handles, an original high-chroma lane palette, avatar graph nodes, and a Refs column. Adds the art direction
  document and ADR-0014, re-validates every color token, and redraws all mockups (#166).

[Unreleased]: https://github.com/kkdy21/overgrove/commits/main
