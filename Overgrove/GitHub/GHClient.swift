import Foundation

/// Output of a successful gh command.
struct GHOutput: Sendable, Equatable {
    let stdout: Data
    /// Masked stderr; gh prints hints and warnings here.
    let stderr: MaskedText
}

/// Runs allowlisted gh commands (git-command-catalog.md §5, ADR-0004).
///
/// Every gh process in the app goes through here:
/// - the executable is looked up at fixed paths only, never through the user's PATH (ADR-0008);
/// - the working directory is an app-owned, empty folder (`0700`) under the user's temporary directory, never a
///   repository, so a git that gh runs internally cannot pick up a repository's configuration (T1–T7);
/// - the environment is rebuilt from an allowlist: tokens, host and repository overrides, config directories, and
///   browser or editor commands from the parent never reach gh, and telemetry, prompts, and update checks are off;
/// - commands are `GHCommand` cases only, and repository-scoped ones always pass `--repo`.
///
/// The app never reads, stores, or logs a token: `--show-token` has no case, raw `auth status` output never leaves
/// this actor (only the parsed `GHAuthStatus` does), and `GHAuthParser` ignores token-related fields.
actor GHClient {
    /// Search order for gh. Homebrew on Apple silicon first, then Intel Homebrew (docs/README.md §2.1).
    static let defaultExecutableCandidates = [
        URL(fileURLWithPath: "/opt/homebrew/bin/gh"),
        URL(fileURLWithPath: "/usr/local/bin/gh"),
    ]

    /// Parent variables passed through unchanged. Everything else is dropped (T10, git-command-catalog.md §5).
    static let passthroughVariables = ["HOME", "USER", "TMPDIR"]

    /// Fixed variables for every gh process (git-command-catalog.md §5, ADR-0004 §7).
    static let fixedEnvironment: [String: String] = [
        "PATH": GitEnvironment.path,
        "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1",
        "GH_TELEMETRY": "0",
        "DO_NOT_TRACK": "1",
        "GH_SPINNER_DISABLED": "1",
        "NO_COLOR": "1",
        "GH_PAGER": "cat",
        "LC_ALL": "C",
        "GIT_TERMINAL_PROMPT": "0",
    ]

    /// App-owned working directory for gh. Created on first use with mode `0700`.
    static let defaultNeutralDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("io.github.kkdy21.overgrove.gh-neutral", isDirectory: true)

    /// gh's exit code for "this command needs authentication".
    static let authenticationRequiredExitCode: Int32 = 4

    private let runner: ProcessRunner
    private let parentEnvironment: [String: String]
    private let neutralDirectory: URL
    private let executableCandidates: [URL]
    private let limits: ProcessLimits

    init(
        runner: ProcessRunner = ProcessRunner(),
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        neutralDirectory: URL = GHClient.defaultNeutralDirectory,
        executableCandidates: [URL] = GHClient.defaultExecutableCandidates,
        limits: ProcessLimits = .gh
    ) {
        self.runner = runner
        self.parentEnvironment = parentEnvironment
        self.neutralDirectory = neutralDirectory
        self.executableCandidates = executableCandidates
        self.limits = limits
    }

    /// The complete child environment. Nothing else from `parent` reaches gh: `GH_TOKEN`, `GITHUB_TOKEN`,
    /// `GH_ENTERPRISE_TOKEN`, `GH_HOST`, `GH_REPO`, `GH_CONFIG_DIR`, `BROWSER`, `GH_BROWSER`, `EDITOR`, proxies,
    /// `GIT_*`, `DYLD_*`, and the user's PATH are all ignored.
    static func environment(parent: [String: String]) -> [String: String] {
        var environment = fixedEnvironment
        for key in passthroughVariables {
            if let value = parent[key] { environment[key] = value }
        }
        return environment
    }

    /// The first candidate that is an executable regular file (symbolic links such as Homebrew's are followed).
    static func locateExecutable(candidates: [URL]) -> URL? {
        candidates.first { candidate in
            var isDirectory: ObjCBool = false
            let path = candidate.path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    // MARK: - Commands

    /// Login state for github.com (parsing-spec.md §10.1).
    func authStatus() async throws -> GHAuthStatus {
        guard let status = try await authReport().status else {
            throw GHError(ParseError(parser: "GHAuthParser", offset: 0, reason: "invalid login"))
        }
        return status
    }

    /// Login state for github.com and the hosts gh is logged in to (parsing-spec.md §10.1, ADR-0025 §1).
    ///
    /// A missing gh is `.notInstalled`, not an error, so the issue panel can explain it (ADR-0004 §4). With
    /// `--json`, gh exits 0 even when authentication is broken, so the decision comes from the JSON alone; the exit
    /// code only explains output that is not JSON (for example, a gh too old to know `--json`).
    func authReport() async throws -> GHAuthReport {
        let result: ProcessResult
        do {
            result = try await launch(.authStatus)
        } catch GHError.notInstalled {
            return GHAuthReport(status: .notInstalled, hosts: [])
        }
        try checkLimits(result)
        do {
            return try GHAuthParser.parseReport(result.stdout)
        } catch let error as ParseError {
            switch failure(result) {
            case .notLoggedIn: return GHAuthReport(status: .notLoggedIn, hosts: [])
            case let failure where result.termination != .exited(code: 0): throw failure
            default: throw GHError(error)
            }
        }
    }

    /// First line of `gh --version`, e.g. `gh version 2.95.0 (2026-06-17)`, for onboarding.
    func version() async throws -> String {
        let output = try await run(.version)
        let text = String(decoding: output.stdout, as: UTF8.self)
        return String(text.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
    }

    /// Open issues of a GitHub repository (parsing-spec.md §10.2).
    func issues(in repository: GitHubRepository) async throws -> [Issue] {
        let output = try await run(.issueList(repo: repository))
        do {
            return try IssueParser.parse(output.stdout, host: repository.host)
        } catch let error as ParseError {
            throw GHError(error)
        }
    }

    /// Pull requests of a GitHub repository (parsing-spec.md §10.3, ADR-0023).
    func pullRequests(in repository: GitHubRepository) async throws -> [PullRequest] {
        let output = try await run(.prList(repo: repository))
        do {
            return try PullRequestParser.parse(output.stdout, host: repository.host)
        } catch let error as ParseError {
            throw GHError(error)
        }
    }

    /// Runs a command that must exit 0 with complete output.
    ///
    /// Private on purpose: callers get parsed values only, so raw gh output (including `auth status`) stays here.
    private func run(_ command: GHCommand) async throws -> GHOutput {
        let result = try await launch(command)
        try checkLimits(result)
        guard result.termination == .exited(code: 0) else { throw failure(result) }
        return GHOutput(stdout: result.stdout, stderr: MaskedText(masking: result.stderr))
    }

    // MARK: - Execution

    private func launch(_ command: GHCommand) async throws -> ProcessResult {
        guard let executable = Self.locateExecutable(candidates: executableCandidates) else {
            throw GHError.notInstalled
        }
        // Created on demand; if this fails, the spawn below fails with ENOENT and reports `launchFailed`.
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
            throw GHError.notInstalled  // removed between lookup and launch
        } catch ProcessRunnerError.spawnFailed(let code), ProcessRunnerError.waitFailed(let code) {
            throw GHError.launchFailed(errno: code)
        } catch ProcessRunnerError.invalidArgument, ProcessRunnerError.invalidEnvironment {
            throw GHError.invalidArgument(reason: "argument or environment value contains a NUL byte")
        } catch is CancellationError {
            throw GHError.cancelled
        }
    }

    /// Timeouts and truncated stdout fail regardless of the exit code: partial JSON is never parsed.
    private func checkLimits(_ result: ProcessResult) throws {
        if result.timedOut { throw GHError.timeout(seconds: Int(limits.timeout.components.seconds)) }
        if result.stdoutTruncated { throw GHError.outputTruncated }
    }

    private func failure(_ result: ProcessResult) -> GHError {
        if result.termination == .exited(code: Self.authenticationRequiredExitCode) { return .notLoggedIn }
        // Killed by a signal we did not send: report like a shell does (128 + signal).
        let code = result.termination.exitCode ?? (result.termination.signal.map { 128 + $0 } ?? -1)
        return .nonZeroExit(code: code, detail: MaskedText(masking: result.stderr))
    }
}
