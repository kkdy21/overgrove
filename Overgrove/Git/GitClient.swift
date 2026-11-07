import Foundation
import os

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
/// into `GitError` from masked stderr.
///
/// Concurrency (overview.md §4): queries and fetches use separate slot pools, so a fetch that holds its slot for up
/// to 120 seconds never delays a status refresh. Each run uses two file descriptors, and fan-out across many
/// worktrees must not exhaust them. A repository fetches one remote at a time, because worktrees share its refs.
actor GitClient {
    static let defaultConcurrency = 4
    /// Fetch slots for the whole app (performance-budget.md §4, recommendation 8).
    static let defaultFetchConcurrency = 2

    let environment: GitEnvironment
    private let runner: ProcessRunner
    private let parentEnvironment: [String: String]
    private let neutralDirectory: URL
    private let maximumConcurrency: Int
    private let maximumFetchConcurrency: Int
    private let fetchLimits: ProcessLimits
    private var pools: [SlotPool: Slots] = [:]
    private var peaks: [SlotPool: Int] = [:]

    /// The most query processes that ran at once.
    var peakConcurrency: Int { peaks[.query] ?? 0 }
    /// The most fetch processes that ran at once.
    var peakFetchConcurrency: Int { peaks[.fetch] ?? 0 }

    /// - Parameter fetchLimits: Timeout and output caps for `fetch`; tests shorten the timeout.
    init(
        environment: GitEnvironment,
        runner: ProcessRunner = ProcessRunner(),
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        neutralDirectory: URL = FileManager.default.temporaryDirectory,
        maximumConcurrency: Int = GitClient.defaultConcurrency,
        maximumFetchConcurrency: Int = GitClient.defaultFetchConcurrency,
        fetchLimits: ProcessLimits = .fetch
    ) {
        self.environment = environment
        self.runner = runner
        self.parentEnvironment = parentEnvironment
        self.neutralDirectory = neutralDirectory
        self.maximumConcurrency = max(1, maximumConcurrency)
        self.maximumFetchConcurrency = max(1, maximumFetchConcurrency)
        self.fetchLimits = fetchLimits
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
        try await acquire(.query)
        defer { release(.query) }
        return try await execute(
            arguments: arguments,
            in: workingDirectory,
            location: command.location,
            limits: .query,
            acceptedExitCodes: command.acceptedExitCodes,
            trustedSSHCommand: safety.trustedSSHCommand
        )
    }

    /// Runs `git fetch` for one remote with the fetch-only authentication arguments (git-command-catalog.md §2.3, §4).
    ///
    /// Fetches of the same repository (`Repository.id`, shared by its worktrees) run one at a time, in request
    /// order; others wait. A waiting fetch holds no slot. Cancelling the task stops git (SIGTERM, then SIGKILL) and
    /// throws `GitError.cancelled`; after `fetchLimits.timeout` (120 seconds) it throws `GitError.timeout`.
    ///
    /// - Parameter progress: Called with each new progress update, in order, on a serial background queue. Hop to
    ///   the main actor before touching UI state. A few updates may still arrive after cancellation or after this
    ///   method returns, and a server can forge them: use them for display only, never to judge success.
    func fetch(
        _ command: FetchCommand,
        in repository: Repository,
        safety: RepoSafetyContext,
        progress: (@Sendable (FetchProgress) -> Void)? = nil
    ) async throws -> GitOutput {
        guard safety.isInspected else {
            throw GitError.configInspectionFailed(reason: "repository configuration has not been inspected")
        }
        if let reason = safety.fetchBlockingReason {
            throw GitError.configInspectionFailed(reason: reason)
        }
        let arguments = environment.arguments(
            for: command.subcommandArguments(),
            neutralization: safety.neutralization,
            fetchAuthentication: safety.fetchAuthentication,
            fetchOverrides: command.configurationOverrides()
        )
        // The repository first: a fetch that waits for its turn must not hold one of the shared fetch slots.
        try await acquire(.repository(repository.id))
        defer { release(.repository(repository.id)) }
        try await acquire(.fetch)
        defer { release(.fetch) }
        return try await execute(
            arguments: arguments,
            in: repository.rootURL ?? repository.commonGitDirectoryURL,
            location: .repository,
            limits: fetchLimits,
            acceptedExitCodes: [0],
            trustedSSHCommand: safety.trustedSSHCommand,
            stderrObserver: progress.map(Self.progressObserver)
        )
    }

    /// Turns raw stderr chunks into progress updates. Only phases and numbers leave the parser, never server text.
    ///
    /// The caller's closure runs on its own serial queue, not on the process queue: that queue also drains the pipes
    /// and fires the timeout and cancellation, so a slow or blocked callback must not be able to stall them
    /// (security review of #197).
    private static func progressObserver(
        _ report: @escaping @Sendable (FetchProgress) -> Void
    ) -> @Sendable (Data) -> Void {
        let parser = OSAllocatedUnfairLock(initialState: FetchProgressParser())
        let delivery = DispatchQueue(label: "overgrove.fetch.progress")
        return { chunk in
            let updates = parser.withLock { $0.consume(chunk) }
            guard !updates.isEmpty else { return }
            delivery.async {
                for update in updates { report(update) }
            }
        }
    }

    // MARK: - Execution

    private func execute(
        arguments: [String],
        in directory: URL,
        location: ReadOnlyGitCommand.Location,
        limits: ProcessLimits,
        acceptedExitCodes: Set<Int32>,
        trustedSSHCommand: String?,
        stderrObserver: (@Sendable (Data) -> Void)? = nil
    ) async throws -> GitOutput {
        let request = ProcessRequest(
            executable: environment.executable,
            arguments: arguments,
            environment: GitEnvironment.environment(parent: parentEnvironment, trustedSSHCommand: trustedSSHCommand),
            currentDirectory: directory,
            limits: limits
        )
        let result: ProcessResult
        do {
            result = try await runner.run(request, stderrObserver: stderrObserver)
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

    // MARK: - Slots

    /// A pool of slots: queries, fetches, or the single fetch slot of one repository.
    private enum SlotPool: Hashable {
        case query
        case fetch
        case repository(String)
    }

    private struct Slots {
        var running = 0
        var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    }

    private func capacity(of pool: SlotPool) -> Int {
        switch pool {
        case .query: maximumConcurrency
        case .fetch: maximumFetchConcurrency
        case .repository: 1
        }
    }

    /// Waits for a free slot in `pool`, first come first served. A cancelled waiter leaves the queue immediately and
    /// throws `GitError.cancelled`.
    private func acquire(_ pool: SlotPool) async throws {
        if Task.isCancelled { throw GitError.cancelled }
        var slots = pools[pool] ?? Slots()
        if slots.running < capacity(of: pool) {
            slots.running += 1
            pools[pool] = slots
            recordPeak(of: pool)
            return
        }
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pools[pool, default: Slots()].waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, in: pool) }
        }
        guard granted else { throw GitError.cancelled }
        recordPeak(of: pool)
    }

    private func release(_ pool: SlotPool) {
        guard var slots = pools[pool] else { return }
        if slots.waiters.isEmpty {
            slots.running -= 1
        } else {
            // Hand the slot over; `running` is unchanged.
            slots.waiters.removeFirst().continuation.resume(returning: true)
        }
        store(slots, for: pool)
    }

    private func cancelWaiter(_ id: UUID, in pool: SlotPool) {
        guard var slots = pools[pool], let index = slots.waiters.firstIndex(where: { $0.id == id }) else { return }
        slots.waiters.remove(at: index).continuation.resume(returning: false)
        store(slots, for: pool)
    }

    /// Repository pools are dropped when idle, so their number stays bounded by the repositories fetching now.
    private func store(_ slots: Slots, for pool: SlotPool) {
        if case .repository = pool, slots.running == 0, slots.waiters.isEmpty {
            pools[pool] = nil
        } else {
            pools[pool] = slots
        }
    }

    private func recordPeak(of pool: SlotPool) {
        guard pool == .query || pool == .fetch else { return }
        peaks[pool] = max(peaks[pool] ?? 0, pools[pool]?.running ?? 0)
    }
}
