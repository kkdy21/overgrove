import Foundation

/// The git executable and the hardened invocation context every git call uses
/// (docs/design/security-review.md §3.1–§3.2, git-command-catalog.md §1–§2, ADR-0008).
///
/// Final argument order: `git [common] [neutralization] [fetch auth] [fetch overrides] <subcommand ...>`. `GitClient` assembles it with
/// `arguments(for:neutralization:fetchAuthentication:)`; `GitCommand` cases only define the subcommand part.
struct GitEnvironment: Sendable, Equatable {
    /// Common safety arguments placed before every subcommand (security-review.md §3.1).
    static let commonArguments: [String] = [
        "--no-pager",
        "--no-optional-locks",
        "--literal-pathspecs",
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.askPass=",
        "-c", "protocol.ext.allow=never",
        "-c", "protocol.fd.allow=never",
        // Related repository settings are neutralized (#350, T5).
        "-c", "alias.remote-https=",
        "-c", "alias.remote-ssh=",
        "-c", "alias.remote-git=",
        "-c", "alias.remote-file=",
        "-c", "alias.remote-http=",
        "-c", "help.autocorrect=0",
        "-c", "core.alternateRefsCommand=",
        "-c", "log.showSignature=false",
        "-c", "gc.auto=0",
        "-c", "maintenance.auto=false",
        // `git diff` refreshes and rewrites the index for stat-dirty paths despite --no-optional-locks (#208).
        "-c", "diff.autoRefreshIndex=false",
        "-c", "color.ui=never",
        // A repository's diff.suppressBlankEmpty drops the leading space of empty context lines in patches; it has
        // no command-line option (#239).
        "-c", "diff.suppressBlankEmpty=false",
        // A repository's i18n.logOutputEncoding or i18n.commitEncoding re-encodes the whole formatted output, `-z`
        // separators included, and some encodings (JOHAB, CP1361) turn message text into NUL bytes that shift fields
        // (#205). Pinning the output to UTF-8 overrides both.
        "-c", "i18n.logOutputEncoding=UTF-8",
        // A repository's log.follow=true makes `git log -- <one path>` follow renames, so S-09's "Follow renames" off
        // still followed (#310). `fileHistory` passes `--follow` itself when it wants it; an option beats the config.
        "-c", "log.follow=false",
    ]

    /// The neutralizing arguments of #350: one per allowed transport, and one more. Part of `commonArguments`; a test
    /// keeps the two in step.
    static let remoteHelperArguments: [String] =
        allowedProtocols.split(separator: ":").flatMap { ["-c", "alias.remote-\($0)="] } + ["-c", "help.autocorrect=0"]

    /// Fixed search path for the child; the user's shell PATH is never used (SEC-T10-02).
    static let path = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    /// Used when no trusted `core.sshCommand` exists: never prompt (host keys, passphrases) in the background.
    static let defaultSSHCommand = "ssh -o BatchMode=yes"

    /// Transports git may use, as `GIT_ALLOW_PROTOCOL` (security-review.md §3.2, #161).
    ///
    /// The variable acts like `protocol.allow=never` with only these set to `always`, and it overrides every config
    /// value, including a repository's own `protocol.<name>.allow=always`. So a repository cannot make fetch run an
    /// installed `git-remote-<helper>` through a `<helper>::` URL, `remote.<n>.vcs`, or `url.<base>.insteadOf` (T5).
    /// The common `protocol.ext.allow=never` and `protocol.fd.allow=never` arguments stay as defense in depth.
    static let allowedProtocols = "https:ssh:git:file:http"

    /// The first git on the newest line whose `GIT_NO_LAZY_FETCH` also stops a lazy fetch during fetch (#212, #317).
    /// That came with the May 2024 security releases: 2.45.1, and 2.44.1 with backports to 2.39.4, 2.40.2, 2.41.1,
    /// 2.42.2, and 2.43.4. 2.44.0 predates the variable, and 2.45.0 has it only for other lazy fetches. Comparing
    /// versions refuses the older fixed releases too, which errs on the safe side.
    static let lazyFetchControlVersion = GitVersion(major: 2, minor: 45, patch: 1)

    /// Parent variables that are passed through unchanged. Everything else is dropped (T10).
    static let passthroughVariables = ["HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"]

    let executable: URL
    let version: GitVersion

    /// The complete child environment (security-review.md §3.2). Nothing else from `parent` reaches git, so
    /// `GIT_DIR`, `GIT_CONFIG_*`, `GIT_SSH_COMMAND`, `GIT_EXEC_PATH`, `GIT_ALLOW_PROTOCOL`, `DYLD_*`, and the user's
    /// PATH are ignored.
    ///
    /// - Parameters:
    ///   - trustedSSHCommand: `core.sshCommand` from a trusted scope (system, global, Apple built-in), as found by
    ///     `RepoConfigInspector`. Repository-local values are never passed here (T5).
    ///   - allowsTransport: `false` for queries. They never need a remote, but in a partial clone a read that needs a
    ///     missing object makes git lazy-fetch it from the promisor remote, which runs the repository's own
    ///     `remote.<n>.uploadpack` or credential helper (#212). An empty `GIT_ALLOW_PROTOCOL` refuses every transport
    ///     before anything runs, on every supported git (protocol policy predates 2.36). The default is `false`, so a
    ///     caller that forgets to choose gets no network (#215); only `GitClient.fetch` passes `true`.
    static func environment(
        parent: [String: String],
        trustedSSHCommand: String? = nil,
        allowsTransport: Bool = false
    ) -> [String: String] {
        var environment: [String: String] = [
            "LC_ALL": "C",
            "LANG": "C",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_PAGER": "cat",
            "PAGER": "cat",
            "GIT_ASKPASS": "",
            "SSH_ASKPASS": "",
            "GIT_PROXY_COMMAND": "",
            "GIT_ALLOW_PROTOCOL": allowsTransport ? allowedProtocols : "",
            // Second layer: no lazy fetch from a promisor remote, for any command (#212). Older git ignores it, and
            // before the May 2024 security releases it does not cover every path (#317, lazyFetchControlVersion).
            "GIT_NO_LAZY_FETCH": "1",
            "GIT_SSH_COMMAND": trustedSSHCommand ?? defaultSSHCommand,
            "PATH": path,
        ]
        for key in passthroughVariables {
            if let value = parent[key] { environment[key] = value }
        }
        return environment
    }

    /// `git [common] [neutralization] [fetch auth] [fetch overrides] <subcommand ...>` (git-command-catalog.md §1).
    /// Later `-c` values win, so the fetch overrides come last before the subcommand (#209).
    func arguments(
        for subcommand: [String],
        neutralization: [String] = [],
        fetchAuthentication: [String] = [],
        fetchOverrides: [String] = []
    ) -> [String] {
        Self.commonArguments + neutralization + fetchAuthentication + fetchOverrides + subcommand
    }

    // MARK: Discovery

    /// Finds git without going through the `/usr/bin/git` shim, then checks its version.
    ///
    /// The shim costs ~8 ms per call (benchmark-plan.md) and, on a Mac without developer tools, opens an
    /// "install developer tools" dialog. `xcode-select -p` does neither, so the real binary under the active
    /// developer directory is resolved once and used directly.
    static func discover(
        runner: ProcessRunner = ProcessRunner(),
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        developerDirectory: (() async -> URL?)? = nil
    ) async throws -> GitEnvironment {
        let environment = environment(parent: parentEnvironment, allowsTransport: false)
        let directory: URL?
        if let developerDirectory {
            directory = await developerDirectory()
        } else {
            directory = await activeDeveloperDirectory(runner: runner, environment: environment)
        }
        guard let directory else { throw GitError.executableNotFound(path: "/usr/bin/git") }
        return try await probe(
            executable: directory.appendingPathComponent("usr/bin/git"), runner: runner,
            parentEnvironment: parentEnvironment)
    }

    /// The git to use: the one chosen in Settings when it passes ADR-0019's rules, else the default (#106).
    ///
    /// A chosen git is checked on every call. If it fails any rule or its `git version` check, this throws
    /// `chosenExecutableRejected` with the reason and never falls back to the default git (fail closed). The
    /// `/usr/bin/git` shim means the default.
    ///
    /// - Parameter protectedDirectories: Called only for a chosen git, so the default git reads no repository file
    ///   (`GitExecutablePolicy.protectedDirectories(for:)` of the registered repositories).
    static func resolve(
        chosenPath: String?,
        protectedDirectories: @Sendable () -> [URL],
        runner: ProcessRunner = ProcessRunner(),
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        developerDirectory: (() async -> URL?)? = nil
    ) async throws -> GitEnvironment {
        guard let chosenPath, !chosenPath.isEmpty, !GitExecutablePolicy.isShim(chosenPath) else {
            return try await discover(
                runner: runner, parentEnvironment: parentEnvironment, developerDirectory: developerDirectory)
        }
        let shown = PathValidator.displayable(chosenPath)
        let resolved: URL
        do {
            switch try GitExecutablePolicy.check(path: chosenPath, protectedDirectories: protectedDirectories()) {
            case .useDefault:
                return try await discover(
                    runner: runner, parentEnvironment: parentEnvironment, developerDirectory: developerDirectory)
            case .chosen(_, let real):
                resolved = real
            }
        } catch let rejection as GitExecutablePolicy.Rejection {
            throw GitError.chosenExecutableRejected(path: shown, reason: rejection.message)
        }
        do {
            // The real file that passed the rules, so a link swapped afterwards does not change what runs.
            return try await probe(executable: resolved, runner: runner, parentEnvironment: parentEnvironment)
        } catch GitError.cancelled {
            throw GitError.cancelled
        } catch let error as GitError {
            // Too old, not git, or failing to run: the same refusal, so Use Default is offered (ADR-0019 §4).
            throw GitError.chosenExecutableRejected(path: shown, reason: error.message)
        }
    }

    /// Runs `git version` on `executable` with the query environment and checks the minimum version (ADR-0008 §3).
    ///
    /// Only the version check: callers decide which executable may be probed. The default comes from `discover`; a
    /// git chosen in Settings must pass ADR-0019's path, ownership, and permission rules first (#106).
    static func probe(
        executable: URL,
        runner: ProcessRunner = ProcessRunner(),
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> GitEnvironment {
        let environment = environment(parent: parentEnvironment, allowsTransport: false)
        let result: ProcessResult
        do {
            result = try await runner.run(
                ProcessRequest(
                    executable: executable,
                    arguments: ["version"],
                    environment: environment,
                    currentDirectory: nil,
                    limits: .query
                )
            )
        } catch ProcessRunnerError.executableNotFound(let path) {
            throw GitError.executableNotFound(path: path)
        } catch ProcessRunnerError.spawnFailed(let code) {
            throw GitError.launchFailed(errno: code)
        } catch is CancellationError {
            throw GitError.cancelled
        }
        guard result.succeeded else {
            throw GitError.classify(
                exitCode: result.termination.exitCode,
                signal: result.termination.signal,
                timedOut: result.timedOut,
                outputTruncated: result.isTruncated,
                timeoutSeconds: 15,
                stderr: result.stderr
            ) ?? .launchFailed(errno: 0)
        }
        let version: GitVersion
        do {
            version = try VersionParser.parse(result.stdout)
        } catch let error as ParseError {
            throw GitError(error)
        }
        guard version.isSupported else { throw GitError.unsupportedVersion(found: version) }
        return GitEnvironment(executable: executable, version: version)
    }

    /// `xcode-select -p`, which never shows the developer-tools install dialog.
    private static func activeDeveloperDirectory(
        runner: ProcessRunner,
        environment: [String: String]
    ) async -> URL? {
        let request = ProcessRequest(
            executable: URL(fileURLWithPath: "/usr/bin/xcode-select"),
            arguments: ["-p"],
            environment: environment,
            currentDirectory: nil,
            limits: .query
        )
        guard let result = try? await runner.run(request), result.succeeded else { return nil }
        let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\n") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

extension ProcessTermination {
    var exitCode: Int32? {
        if case .exited(let code) = self { return code }
        return nil
    }

    var signal: Int32? {
        if case .signaled(let signal) = self { return signal }
        return nil
    }
}
