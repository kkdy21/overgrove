# Security Policy

Overgrove is a macOS app that **runs the system `git` binary against repositories you point it at**.
That makes untrusted repositories and command injection the primary threats. We take reports seriously.

## Reporting a vulnerability

**Do not open a public issue, discussion, or pull request for security problems.**

Use GitHub's private vulnerability reporting instead:

1. Go to the [Security tab → Report a vulnerability](https://github.com/kkdy21/overgrove/security/advisories/new).
2. Describe the issue, affected version or commit, macOS and `git` versions, and a minimal reproduction.
   If the reproduction needs a crafted repository, describe how to build it (a script is ideal) instead of attaching one.
3. You will get an acknowledgement within **7 days**. We aim to confirm or reject the report within **14 days**
   and to ship a fix or mitigation for confirmed issues within **30 days**, depending on severity.

Please give us a reasonable chance to fix the issue before any public disclosure. We will credit reporters in the
advisory and the changelog unless you ask us not to.

## Supported versions

Overgrove is distributed **as source only** (no signed or notarized binaries).

| Version | Supported |
|---|---|
| `main` (latest commit) | ✅ |
| Latest tagged release (`v0.x`) | ✅ |
| Older tags | ❌ — please update to the latest release |

## What Overgrove does to protect you

Opening a repository in a Git client can execute code configured *by that repository*. Overgrove is designed so that
browsing an untrusted repository does not run that code. In short:

- Every `git` invocation goes through a single client, uses an **argument array (never a shell)**, and places user-supplied
  values after `--`. Refs starting with `-` are rejected.
- Every invocation forces safe settings: `core.fsmonitor=false`, `core.hooksPath=/dev/null`, an empty `core.askPass`,
  `log.showSignature=false`, `ext::`/`fd::` transports disabled, no pager, no optional locks, and automatic
  `gc`/maintenance turned off. Diffs add `--no-ext-diff --no-textconv`; status ignores dirty submodules; fetch does not
  recurse into submodules and pins `--upload-pack`.
- Before running commands, Overgrove inspects repository-local config (including included files) for keys that can
  execute programs: clean/smudge/process filters, `core.sshCommand`, `core.gitProxy`, `remote.<name>.uploadpack`,
  `credential.helper`, signature programs, and others. It warns you and neutralizes them for its own invocations.
  Some keys cannot be overridden with `-c`, so Overgrove uses command-line options or environment variables instead.
  If a key cannot be neutralized safely, Overgrove refuses to query the repository (fail closed).
- The child-process environment is built from an allowlist (`LC_ALL=C`, `GIT_TERMINAL_PROMPT=0`,
  `GIT_OPTIONAL_LOCKS=0`, …) instead of inheriting yours.
- Commands have timeouts and output-size limits.
- Credentials embedded in remote URLs are masked in the UI and in logs.
- The only commands that exist in the code are read-only queries and `git fetch`. There is no code path for
  `push`, `reset`, `clean`, `checkout`, and similar.
- Overgrove never asks for, stores, or transmits tokens. GitHub access is delegated to your `gh` CLI login;
  Git remote authentication is delegated to your existing credential helper or SSH setup.
- No telemetry. Network access is limited to `git fetch` and `gh`.

The full threat model (threats T1–T18), mitigations, and the tests that verify them live in
[`docs/design/security-review.md`](docs/design/security-review.md).

## Known limitations

- Overgrove disables the macOS App Sandbox so it can read repositories anywhere on disk. It relies on the measures
  above instead. Treat it like any other developer tool that runs `git`.
- Git itself can have vulnerabilities. Keep the `git` binary that Overgrove uses up to date.
- `git fetch` contacts the remotes configured in the repository. Do not fetch from repositories whose remotes you do not trust.

## Scope

In scope: the Overgrove source in this repository, its build configuration, and its GitHub Actions workflows.

Out of scope: vulnerabilities in `git`, `gh`, macOS, or Xcode themselves (please report those upstream), and issues
that require an already-compromised user account.
