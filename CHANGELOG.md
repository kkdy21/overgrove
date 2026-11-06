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

[Unreleased]: https://github.com/kkdy21/overgrove/commits/main
