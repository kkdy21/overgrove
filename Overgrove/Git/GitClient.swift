import Foundation

/// Output of a successful (or partially successful) git command.
struct GitOutput: Sendable, Equatable {
    let stdout: Data
    /// Masked stderr, e.g. fetch progress or warnings.
    let stderr: MaskedText
    /// Output hit the size limit; parsers drop the last record and the UI shows a warning (overview.md §6.1).
    let isTruncated: Bool
}

/// Runs allowlisted git commands with the hardened context (git-command-catalog.md §1, ADR-0008).
///
/// Every git process in the app goes through here: final arguments are `git [common] [neutralization]
/// [fetch auth] <subcommand>`, the environment is the allowlist from `GitEnvironment`, and failures are classified
/// into `GitError` from masked stderr. The number of concurrent git processes is capped (each run uses two file
/// descriptors, and fan-out across many worktrees must not exhaust them).
actor GitClient {
    static let defaultConcurrency = 4

    let environment: GitEnvironment
    private let runner: ProcessRunner
    private let parentEnvironment: [String: String]
    private let neutralDirectory: URL
    private let maximumConcurrency: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var peakConcurrency = 0

    init(
        environment: GitEnvironment,
        runner: ProcessRunner = ProcessRunner(),
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        neutralDirectory: URL = FileManager.default.temporaryDirectory,
        maximumConcurrency: Int = GitClient.defaultConcurrency
    ) {
        self.environment = environment
        self.runner = runner
        self.parentEnvironment = parentEnvironment
        self.neutralDirectory = neutralDirectory
        self.maximumConcurrency = max(1, maximumConcurrency)
    }

    /// Runs a read-only command.
    ///
    /// - Parameters:
    ///   - directory: The repository or worktree path. Ignored for `.neutral` commands.
    ///   - neutralization: Arguments from `RepoConfigInspector` for this repository (ADR-0009).
    ///   - trustedSSHCommand: `core.sshCommand` from a trusted scope, if any.
    func run(
        _ command: ReadOnlyGitCommand,
        in directory: URL?,
        neutralization: [String] = [],
        trustedSSHCommand: String? = nil
    ) async throws -> GitOutput {
        let workingDirectory = command.location == .neutral ? neutralDirectory : directory
        guard let workingDirectory else { throw GitError.invalidArgument(reason: "missing working directory") }
        let arguments = environment.arguments(
            for: try command.subcommandArguments(),
            neutralization: neutralization
        )
        return try await execute(
            arguments: arguments,
            in: workingDirectory,
            limits: .query,
            acceptedExitCodes: command.acceptedExitCodes,
            trustedSSHCommand: trustedSSHCommand
        )
    }

    /// Runs `git fetch` for one remote with the fetch-only authentication arguments (git-command-catalog.md §2.3).
    func fetch(
        _ command: FetchCommand,
        in repository: URL,
        neutralization: [String] = [],
        authentication: [String] = [],
        trustedSSHCommand: String? = nil
    ) async throws -> GitOutput {
        let arguments = environment.arguments(
            for: command.subcommandArguments(),
            neutralization: neutralization,
            fetchAuthentication: authentication
        )
        return try await execute(
            arguments: arguments,
            in: repository,
            limits: .fetch,
            acceptedExitCodes: [0],
            trustedSSHCommand: trustedSSHCommand
        )
    }

    // MARK: - Execution

    private func execute(
        arguments: [String],
        in directory: URL,
        limits: ProcessLimits,
        acceptedExitCodes: Set<Int32>,
        trustedSSHCommand: String?
    ) async throws -> GitOutput {
        await acquire()
        defer { release() }
        if Task.isCancelled { throw GitError.cancelled }

        let request = ProcessRequest(
            executable: environment.executable,
            arguments: arguments,
            environment: GitEnvironment.environment(parent: parentEnvironment, trustedSSHCommand: trustedSSHCommand),
            currentDirectory: directory,
            limits: limits
        )
        let result: ProcessResult
        do {
            result = try await runner.run(request)
        } catch ProcessRunnerError.executableNotFound(let path) {
            throw GitError.executableNotFound(path: path)
        } catch ProcessRunnerError.spawnFailed(let code) {
            throw code == ENOENT ? GitError.worktreeMissing(path: directory.path) : GitError.launchFailed(errno: code)
        } catch ProcessRunnerError.waitFailed(let code) {
            throw GitError.launchFailed(errno: code)
        } catch ProcessRunnerError.invalidArgument, ProcessRunnerError.invalidEnvironment {
            throw GitError.invalidArgument(reason: "argument contains a NUL byte")
        } catch is CancellationError {
            throw GitError.cancelled
        }

        let stderr = MaskedText(masking: result.stderr)
        if result.timedOut {
            throw GitError.timeout(seconds: Int(limits.timeout.components.seconds))
        }
        if result.isTruncated {
            return GitOutput(stdout: result.stdout, stderr: stderr, isTruncated: true)
        }
        if let code = result.termination.exitCode, acceptedExitCodes.contains(code) {
            return GitOutput(stdout: result.stdout, stderr: stderr, isTruncated: false)
        }
        throw GitError.classify(
            exitCode: result.termination.exitCode,
            signal: result.termination.signal,
            timedOut: false,
            outputTruncated: false,
            timeoutSeconds: Int(limits.timeout.components.seconds),
            stderr: result.stderr
        ) ?? GitError.nonZeroExit(code: result.termination.exitCode ?? -1, detail: stderr)
    }

    private func acquire() async {
        if running < maximumConcurrency {
            running += 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
        peakConcurrency = max(peakConcurrency, running)
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()  // hand the slot over directly; `running` stays the same
        }
    }
}
