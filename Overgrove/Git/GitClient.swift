import Foundation

/// Output of a successful (or partially successful) git command.
struct GitOutput: Sendable, Equatable {
    let stdout: Data
    /// Masked stderr, e.g. fetch progress or warnings.
    let stderr: MaskedText
    /// stdout hit the size limit; parsers drop the last record and the UI shows a warning (overview.md §6.1).
    let isTruncated: Bool
}

/// Per-repository arguments that neutralize the repository's own configuration (ADR-0009).
///
/// Build it from `RepoConfigInspector`. `preInspection` exists only for the commands that run before the
/// configuration is known (`version`, `probeRepository`, `configList`); `GitClient` refuses anything else with it.
struct RepoSafetyContext: Sendable, Equatable {
    let neutralization: [String]
    let fetchAuthentication: [String]
    let trustedSSHCommand: String?
    let isInspected: Bool
    /// Set when the repository's configuration makes fetching unsafe; queries still run.
    let fetchBlockingReason: String?

    static let preInspection = RepoSafetyContext(
        neutralization: [],
        fetchAuthentication: [],
        trustedSSHCommand: nil,
        isInspected: false,
        fetchBlockingReason: nil
    )

    init(
        inspectedNeutralization: [String],
        fetchAuthentication: [String],
        trustedSSHCommand: String?,
        fetchBlockingReason: String? = nil
    ) {
        self.init(
            neutralization: inspectedNeutralization,
            fetchAuthentication: fetchAuthentication,
            trustedSSHCommand: trustedSSHCommand,
            isInspected: true,
            fetchBlockingReason: fetchBlockingReason
        )
    }

    private init(
        neutralization: [String],
        fetchAuthentication: [String],
        trustedSSHCommand: String?,
        isInspected: Bool,
        fetchBlockingReason: String?
    ) {
        self.neutralization = neutralization
        self.fetchAuthentication = fetchAuthentication
        self.trustedSSHCommand = trustedSSHCommand
        self.isInspected = isInspected
        self.fetchBlockingReason = fetchBlockingReason
    }
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
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
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
    ///   - safety: From `RepoConfigInspector`; `.preInspection` only for commands that do not require inspection.
    func run(_ command: ReadOnlyGitCommand, in directory: URL?, safety: RepoSafetyContext) async throws -> GitOutput {
        if command.requiresInspection && !safety.isInspected {
            throw GitError.configInspectionFailed(reason: "repository configuration has not been inspected")
        }
        let workingDirectory = command.location == .neutral ? neutralDirectory : directory
        guard let workingDirectory else { throw GitError.invalidArgument(reason: "missing working directory") }
        let arguments = environment.arguments(
            for: try command.subcommandArguments(),
            neutralization: safety.neutralization
        )
        return try await execute(
            arguments: arguments,
            in: workingDirectory,
            location: command.location,
            limits: .query,
            acceptedExitCodes: command.acceptedExitCodes,
            trustedSSHCommand: safety.trustedSSHCommand
        )
    }

    /// Runs `git fetch` for one remote with the fetch-only authentication arguments (git-command-catalog.md §2.3).
    func fetch(_ command: FetchCommand, in repository: URL, safety: RepoSafetyContext) async throws -> GitOutput {
        guard safety.isInspected else {
            throw GitError.configInspectionFailed(reason: "repository configuration has not been inspected")
        }
        if let reason = safety.fetchBlockingReason {
            throw GitError.configInspectionFailed(reason: reason)
        }
        let arguments = environment.arguments(
            for: command.subcommandArguments(),
            neutralization: safety.neutralization,
            fetchAuthentication: safety.fetchAuthentication
        )
        return try await execute(
            arguments: arguments,
            in: repository,
            location: .repository,
            limits: .fetch,
            acceptedExitCodes: [0],
            trustedSSHCommand: safety.trustedSSHCommand
        )
    }

    // MARK: - Execution

    private func execute(
        arguments: [String],
        in directory: URL,
        location: ReadOnlyGitCommand.Location,
        limits: ProcessLimits,
        acceptedExitCodes: Set<Int32>,
        trustedSSHCommand: String?
    ) async throws -> GitOutput {
        try await acquire()
        defer { release() }

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
            if code == ENOENT && (location == .worktree || location == .repository) {
                throw GitError.worktreeMissing(path: directory.path)
            }
            throw GitError.launchFailed(errno: code)
        } catch ProcessRunnerError.waitFailed(let code) {
            throw GitError.launchFailed(errno: code)
        } catch ProcessRunnerError.invalidArgument, ProcessRunnerError.invalidEnvironment {
            throw GitError.invalidArgument(reason: "argument contains a NUL byte")
        } catch is CancellationError {
            throw GitError.cancelled
        }

        let stderr = MaskedText(masking: result.stderr)
        let timeoutSeconds = Int(limits.timeout.components.seconds)
        if result.timedOut { throw GitError.timeout(seconds: timeoutSeconds) }
        if let code = result.termination.exitCode {
            // The exit code decides success; truncation alone never turns a failure into a partial success.
            if acceptedExitCodes.contains(code) {
                return GitOutput(stdout: result.stdout, stderr: stderr, isTruncated: result.stdoutTruncated)
            }
        } else if result.stdoutTruncated {
            // We stopped git ourselves because stdout hit the limit: a usable partial result.
            return GitOutput(stdout: result.stdout, stderr: stderr, isTruncated: true)
        }
        throw GitError.classify(
            exitCode: result.termination.exitCode,
            signal: result.termination.signal,
            timedOut: false,
            outputTruncated: false,
            timeoutSeconds: timeoutSeconds,
            stderr: result.stderr
        ) ?? GitError.nonZeroExit(code: result.termination.exitCode ?? -1, detail: stderr)
    }

    /// Waits for a free slot. A cancelled waiter leaves the queue immediately and throws `GitError.cancelled`.
    private func acquire() async throws {
        if Task.isCancelled { throw GitError.cancelled }
        if running < maximumConcurrency {
            running += 1
            peakConcurrency = max(peakConcurrency, running)
            return
        }
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        guard granted else { throw GitError.cancelled }
        peakConcurrency = max(peakConcurrency, running)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().continuation.resume(returning: true)  // hand the slot over; `running` is unchanged
        }
    }
}
