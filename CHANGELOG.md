# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the major version is `0`, minor versions may contain breaking changes.

## [Unreleased]

### Added

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
- Open on GitHub for branches opens the repository of the remote each branch tracks, so in a fork flow a branch
  tracking your fork opens the fork.

### Changed

- Process: the project board follows issues, pull requests, and claims automatically (`board-sync`, ADR-0016), and
  running several maintainer sessions in parallel has explicit rules (separate worktrees, assign before starting).

- Design: the main window uses its own panel theme — three rounded, resizable, independently scrolling panels with
  grab handles, an original high-chroma lane palette, avatar graph nodes, and a Refs column. Adds the art direction
  document and ADR-0014, re-validates every color token, and redraws all mockups (#166).

[Unreleased]: https://github.com/kkdy21/overgrove/commits/main
