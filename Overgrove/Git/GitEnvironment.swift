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
        "-c", "core.alternateRefsCommand=",
        "-c", "log.showSignature=false",
        "-c", "gc.auto=0",
        "-c", "maintenance.auto=false",
        // `git diff` refreshes and rewrites the index for stat-dirty paths despite --no-optional-locks (#208).
        "-c", "diff.autoRefreshIndex=false",
        "-c", "color.ui=never",
    ]

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

    /// Parent variables that are passed through unchanged. Everything else is dropped (T10).
    static let passthroughVariables = ["HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"]

    let executable: URL
    let version: GitVersion

    /// The complete child environment (security-review.md §3.2). Nothing else from `parent` reaches git, so
    /// `GIT_DIR`, `GIT_CONFIG_*`, `GIT_SSH_COMMAND`, `GIT_EXEC_PATH`, `GIT_ALLOW_PROTOCOL`, `DYLD_*`, and the user's
    /// PATH are ignored.
    ///
    /// - Parameter trustedSSHCommand: `core.sshCommand` from a trusted scope (system, global, Apple built-in), as
    ///   found by `RepoConfigInspector`. Repository-local values are never passed here (T5).
    static func environment(parent: [String: String], trustedSSHCommand: String? = nil) -> [String: String] {
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
            "GIT_ALLOW_PROTOCOL": allowedProtocols,
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
        let environment = environment(parent: parentEnvironment)
        let directory: URL?
        if let developerDirectory {
            directory = await developerDirectory()
        } else {
            directory = await activeDeveloperDirectory(runner: runner, environment: environment)
        }
        guard let directory else { throw GitError.executableNotFound(path: "/usr/bin/git") }
        let executable = directory.appendingPathComponent("usr/bin/git")

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
