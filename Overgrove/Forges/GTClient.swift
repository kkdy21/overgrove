import Foundation

/// Runs allowlisted gt (gitea/cli) commands (git-command-catalog.md §5.1, ADR-0026). Every gt process in the app goes
/// through here, hardened like `GHClient`:
/// - the executable is looked up at fixed paths only, never through PATH (ADR-0008), and its `--version` line must be
///   gt's (`gt version X.Y.Z`), at least `minimumVersion`, before anything else runs: Graphite's CLI is also `gt`;
/// - the working directory is an app-owned empty folder, never a repository, and `--repo` is always given, so gt does
///   not look for a repository in git remotes;
/// - the environment is rebuilt from an allowlist, with the update notifier and extensions off;
/// - raw output stays in this actor; gt's stderr is dropped, not masked (ADR-0026 §4).
///
/// gt creates no file on first use (gt 1.1.0, measured), so unlike `GLClient` there is no setup check.
///
/// STAND-IN(#154): the execution and hardening code mirrors #154's `GLClient`; once that merges, the shared parts move
/// into one helper.
actor GTClient {
    static let defaultExecutableCandidates = [
        URL(fileURLWithPath: "/opt/homebrew/bin/gt"),
        URL(fileURLWithPath: "/usr/local/bin/gt"),
    ]

    /// The version these rules were checked against (ADR-0026, measured 2026-11-08).
    static let minimumVersion = GitVersion(major: 1, minor: 1, patch: 0)

    static let passthroughVariables = ["HOME", "USER", "TMPDIR"]

    /// Fixed variables for every gt process (git-command-catalog.md §5.1).
    static let fixedEnvironment: [String: String] = [
        "PATH": GitEnvironment.path,
        "LC_ALL": "C",
        "GIT_TERMINAL_PROMPT": "0",
        "NO_COLOR": "1",
        "TERM": "dumb",
        "GITEA_CLI_NO_UPDATE_NOTIFIER": "1",
        "GITEA_CLI_NO_EXTENSIONS": "1",
        "GITEA_CLI_COLOR": "never",
        "GITEA_CLI_PAGER": "cat",
    ]

    /// gt's "no account for this instance" exit code (gt help exit-codes; measured with gt 1.1.0).
    static let authenticationExitCode: Int32 = 4

    static let defaultNeutralDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("io.github.kkdy21.overgrove.gt-neutral", isDirectory: true)

    private let runner: ProcessRunner
    private let parentEnvironment: [String: String]
    private let neutralDirectory: URL
    private let executableCandidates: [URL]
    private let limits: ProcessLimits

    init(
        runner: ProcessRunner = ProcessRunner(),
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        neutralDirectory: URL = GTClient.defaultNeutralDirectory,
        executableCandidates: [URL] = GTClient.defaultExecutableCandidates,
        limits: ProcessLimits = .gh
    ) {
        self.runner = runner
        self.parentEnvironment = parentEnvironment
        self.neutralDirectory = neutralDirectory
        self.executableCandidates = executableCandidates
        self.limits = limits
    }

    /// The complete child environment: the allowlist, nothing else from `parent`.
    static func environment(parent: [String: String]) -> [String: String] {
        var environment = fixedEnvironment
        for key in passthroughVariables {
            if let value = parent[key] { environment[key] = value }
        }
        return environment
    }

    /// `gt version 1.1.0 (2026-11-05)` → 1.1.0; `nil` for any other first line (Graphite's `gt` prints a bare
    /// version number).
    static func parseVersion(_ output: Data) -> GitVersion? {
        let line = String(decoding: output.prefix(256), as: UTF8.self).split(separator: "\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[0] == "gt", parts[1] == "version" else { return nil }
        let numbers = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
            numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
            let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2])
        else { return nil }
        return GitVersion(major: major, minor: minor, patch: patch)
    }

    // MARK: - Commands

    /// Instances gt has usable local credentials for, with a valid https URL (ADR-0026 §2). No request is made.
    func loggedInInstances() async throws -> [GiteaInstance] {
        try await loggedInInstances(executable: try await verifiedExecutable())
    }

    private func loggedInInstances(executable: URL) async throws -> [GiteaInstance] {
        let output = try await run(.authStatus, executable: executable)
        let accounts: [GTAccount]
        do {
            accounts = try GTAuthParser.parse(output)
        } catch {
            // Fail closed: output gt does not normally print means no instance is trusted.
            return []
        }
        var instances: [GiteaInstance] = []
        for account in accounts where account.credentialAvailable {
            if let instance = GiteaInstance(account.host), !instances.contains(instance) { instances.append(instance) }
        }
        return instances
    }

    /// Open issues of `repository`, after gt reports credentials for its instance.
    func issues(in repository: GiteaRepository) async throws -> [Issue] {
        // One version check for the whole load.
        let executable = try await verifiedExecutable()
        guard try await loggedInInstances(executable: executable).contains(repository.instance) else {
            throw GTError.notLoggedIn(instance: repository.instance.url)
        }
        let output: Data
        do {
            output = try await run(.issueList(repository: repository), executable: executable)
        } catch GTError.failed(Self.authenticationExitCode) {
            throw GTError.notLoggedIn(instance: repository.instance.url)
        }
        do {
            return try GTIssueParser.parse(output)
        } catch let error as ParseError {
            throw GTError.parseFailed(parser: error.parser)
        }
    }

    // MARK: - Execution

    /// Runs `command` with a verified executable and returns stdout; any exit other than 0 fails.
    private func run(_ command: GTCommand, executable: URL) async throws -> Data {
        let result = try await launch(command, executable: executable)
        try checkLimits(result)
        guard result.termination == .exited(code: 0) else {
            let code = result.termination.exitCode ?? (result.termination.signal.map { 128 + $0 } ?? -1)
            throw GTError.failed(code: code)
        }
        return result.stdout
    }

    private func verifiedExecutable() async throws -> URL {
        guard let executable = GHClient.locateExecutable(candidates: executableCandidates) else {
            throw GTError.notInstalled
        }
        let result = try await launch(.version, executable: executable)
        try checkLimits(result)
        guard result.termination == .exited(code: 0), let version = Self.parseVersion(result.stdout) else {
            throw GTError.notInstalled
        }
        guard version >= Self.minimumVersion else { throw GTError.unsupportedVersion(found: version.description) }
        return executable
    }

    private func launch(_ command: GTCommand, executable: URL) async throws -> ProcessResult {
        try? FileManager.default.createDirectory(
            at: neutralDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let request = ProcessRequest(
            executable: executable,
            arguments: command.arguments,
            environment: Self.environment(parent: parentEnvironment),
            currentDirectory: neutralDirectory,
            limits: limits
        )
        do {
            return try await runner.run(request)
        } catch ProcessRunnerError.executableNotFound {
            throw GTError.notInstalled
        } catch ProcessRunnerError.spawnFailed(let code), ProcessRunnerError.waitFailed(let code) {
            throw GTError.launchFailed(errno: code)
        } catch ProcessRunnerError.invalidArgument, ProcessRunnerError.invalidEnvironment {
            // Validated types cannot carry a NUL byte; refuse rather than run something else.
            throw GTError.launchFailed(errno: EINVAL)
        } catch is CancellationError {
            throw GTError.cancelled
        }
    }

    private func checkLimits(_ result: ProcessResult) throws {
        if result.timedOut { throw GTError.timeout(seconds: Int(limits.timeout.components.seconds)) }
        if result.stdoutTruncated { throw GTError.outputTruncated }
    }
}
