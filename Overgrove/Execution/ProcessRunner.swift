import Darwin
import Foundation

// The only place in the app that creates processes (docs/README.md §2.2, ADR-0008).
// Callers (GitClient, GHClient) decide *what* to run; this file decides *how* it runs safely:
//   - posix_spawn with an argument vector and an explicit environment (no shell, nothing inherited)
//   - stdin is /dev/null, so a credential prompt can never block (T12)
//   - POSIX_SPAWN_CLOEXEC_DEFAULT: the child receives only fds 0–2, never the app's other descriptors
//   - the child leads its own process group, so termination reaches helpers it spawned (ssh, remote helpers)
//   - timeouts with SIGTERM → grace period → SIGKILL, output caps, cooperative cancellation (T15)
//   - event-driven: no thread blocks in read() or waitpid(), so many concurrent runs cannot starve timers
//   - the exited leader is reaped only at the very end, so its pid/pgid cannot be reused while we still signal it

/// Resource limits for one child process (git-command-catalog.md §2.5).
struct ProcessLimits: Sendable, Equatable {
    var timeout: Duration
    var stdoutLimit: Int
    var stderrLimit: Int
    var terminationGracePeriod: Duration = .seconds(2)

    /// Read-only git queries.
    static let query = ProcessLimits(timeout: .seconds(15), stdoutLimit: 10 << 20, stderrLimit: 64 << 10)
    /// `git fetch`.
    static let fetch = ProcessLimits(timeout: .seconds(120), stdoutLimit: 1 << 20, stderrLimit: 256 << 10)
    /// `gh` commands.
    static let gh = ProcessLimits(timeout: .seconds(15), stdoutLimit: 5 << 20, stderrLimit: 64 << 10)
}

/// What to run. The executable must be an absolute path. The environment is complete: nothing is inherited.
struct ProcessRequest: Sendable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var currentDirectory: URL?
    var limits: ProcessLimits
}

enum ProcessTermination: Sendable, Equatable {
    case exited(code: Int32)
    case signaled(signal: Int32)
}

struct ProcessResult: Sendable, Equatable {
    var termination: ProcessTermination
    var stdout: Data
    var stderr: Data
    /// Output was cut at the limit, or the pipe was abandoned because a stray helper kept it open.
    var stdoutTruncated: Bool
    var stderrTruncated: Bool
    var timedOut: Bool
    var duration: Duration

    var isTruncated: Bool { stdoutTruncated || stderrTruncated }

    /// Exit code 0, complete output, and no timeout.
    var succeeded: Bool { termination == .exited(code: 0) && !timedOut && !isTruncated }
}

enum ProcessRunnerError: Error, Equatable {
    /// The path is not absolute or not an executable regular file.
    case executableNotFound(path: String)
    /// An argument contains a NUL byte, which would silently truncate it.
    case invalidArgument(index: Int)
    /// An environment key is empty or contains `=` or NUL, or its value contains NUL.
    case invalidEnvironment(key: String)
    case spawnFailed(errno: Int32)
    /// The exit status could not be collected. Never reported as success.
    case waitFailed(errno: Int32)
}

struct ProcessRunner: Sendable {
    private let onLaunch: (@Sendable (pid_t) -> Void)?

    /// - Parameter onLaunch: Called with the child's pid right after it starts. Intended for tests.
    init(onLaunch: (@Sendable (pid_t) -> Void)? = nil) {
        self.onLaunch = onLaunch
    }

    /// Runs the process to completion.
    ///
    /// Hitting an output limit or the timeout terminates the process and still returns a result
    /// (`stdoutTruncated`/`stderrTruncated`/`timedOut`). Task cancellation terminates the process, waits until it
    /// is reaped, and throws `CancellationError`.
    ///
    /// - Parameter stderrObserver: Receives stderr as it arrives, in order, never beyond `stderrLimit` (fetch
    ///   progress, #76). It runs on the process's private queue, so it must return quickly. The bytes are raw:
    ///   mask them before showing or logging any text.
    func run(
        _ request: ProcessRequest,
        stderrObserver: (@Sendable (Data) -> Void)? = nil
    ) async throws -> ProcessResult {
        try Self.validate(request)
        try Task.checkCancellation()
        let child = try ChildProcess.spawn(request)
        onLaunch?(child.pid)
        child.start(stderrObserver: stderrObserver)
        return try await withTaskCancellationHandler {
            try await child.result()
        } onCancel: {
            child.cancel()
        }
    }

    private static func validate(_ request: ProcessRequest) throws {
        let path = request.executable.path
        var info = stat()
        guard path.hasPrefix("/"), stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(path, X_OK) == 0
        else { throw ProcessRunnerError.executableNotFound(path: path) }
        for (index, argument) in request.arguments.enumerated() where argument.utf8.contains(0) {
            throw ProcessRunnerError.invalidArgument(index: index)
        }
        for (key, value) in request.environment
        where key.isEmpty || key.contains("=") || key.utf8.contains(0) || value.utf8.contains(0) {
            throw ProcessRunnerError.invalidEnvironment(key: key)
        }
    }
}

// MARK: - Child process lifecycle

/// One running child.
///
/// Concurrency: every mutable property is read and written only on `queue`, a private serial queue that also runs
/// all dispatch source handlers. The entry points (`start`, `result`, `cancel`) hop onto `queue`.
private final class ChildProcess: @unchecked Sendable {
    /// After the leader exits, stray holders of its pipes get this long before the group is killed and the
    /// remaining output is abandoned.
    private static let drainWindow: Duration = .milliseconds(500)
    /// Fallback in case the exit event is missed (e.g. the child exits before the source is registered).
    private static let exitPollInterval: Duration = .seconds(1)
    /// After both pipes close, the exit is checked this often until seen (#87).
    private static let closedPipesPollInterval: Duration = .milliseconds(10)
    private static let readChunk = 64 * 1024

    let pid: pid_t
    private let limits: ProcessLimits
    private let startedAt = ContinuousClock.now
    private let queue: DispatchQueue
    private let stdoutFD: Int32
    private let stderrFD: Int32

    // queue-confined state
    private var sources: [DispatchSourceProtocol] = []
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var timeoutTimer: DispatchSourceTimer?
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutTruncated = false
    private var stderrTruncated = false
    private var exitStatus: ProcessTermination?
    private var waitError: Int32?
    private var timedOut = false
    private var terminating = false
    private var cancelled = false
    private var finished = false
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var stderrObserver: (@Sendable (Data) -> Void)?
    private var outcome: Result<ProcessResult, Error>?

    private init(pid: pid_t, stdoutFD: Int32, stderrFD: Int32, limits: ProcessLimits) {
        self.pid = pid
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
        self.limits = limits
        self.queue = DispatchQueue(label: "overgrove.process.\(pid)")
    }

    // MARK: Spawn

    static func spawn(_ request: ProcessRequest) throws -> ChildProcess {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw ProcessRunnerError.spawnFailed(errno: errno) }
        guard pipe(&errPipe) == 0 else {
            let code = errno
            close(outPipe[0])
            close(outPipe[1])
            throw ProcessRunnerError.spawnFailed(errno: code)
        }
        for fd in [outPipe[0], errPipe[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let directory = request.currentDirectory {
            if #available(macOS 26.0, *) {
                posix_spawn_file_actions_addchdir(&actions, directory.path)
            } else {
                posix_spawn_file_actions_addchdir_np(&actions, directory.path)
            }
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var noBlockedSignals = sigset_t()
        sigemptyset(&noBlockedSignals)
        posix_spawnattr_setsigmask(&attributes, &noBlockedSignals)

        let path = request.executable.path
        let argv = CStringArray([path] + request.arguments)
        let envp = CStringArray(request.environment.map { "\($0.key)=\($0.value)" }.sorted())
        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, argv.pointers, envp.pointers)

        close(outPipe[1])
        close(errPipe[1])
        guard status == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw ProcessRunnerError.spawnFailed(errno: status)
        }
        return ChildProcess(pid: pid, stdoutFD: outPipe[0], stderrFD: errPipe[0], limits: request.limits)
    }

    // MARK: Entry points

    func start(stderrObserver: (@Sendable (Data) -> Void)?) {
        queue.async { [self] in
            self.stderrObserver = stderrObserver
            stdoutSource = makeReader(fd: stdoutFD, isStdout: true)
            stderrSource = makeReader(fd: stderrFD, isStdout: false)

            let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            exitSource.setEventHandler { [self] in checkExit() }
            sources.append(exitSource)
            exitSource.resume()

            let poll = DispatchSource.makeTimerSource(queue: queue)
            let interval = Self.dispatchInterval(Self.exitPollInterval)
            poll.schedule(deadline: .now() + interval, repeating: interval)
            poll.setEventHandler { [self] in checkExit() }
            sources.append(poll)
            poll.resume()

            let timeout = DispatchSource.makeTimerSource(queue: queue)
            timeout.schedule(deadline: .now() + Self.dispatchInterval(limits.timeout))
            timeout.setEventHandler { [self] in
                guard exitStatus == nil, waitError == nil else { return }
                timedOut = true
                terminate()
            }
            timeoutTimer = timeout
            sources.append(timeout)
            timeout.resume()

            checkExit()  // the child may already be gone
        }
    }

    func result() async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let outcome {
                    continuation.resume(with: outcome)
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            guard !finished else { return }
            cancelled = true
            if exitStatus != nil || waitError != nil {
                abandonPipesAndFinish()  // already exited: do not keep draining for a cancelled caller
            } else {
                terminate()
            }
        }
    }

    // MARK: Internals (on queue)

    private func makeReader(fd: Int32, isStdout: Bool) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in drain(fd: fd, isStdout: isStdout) }
        source.setCancelHandler { close(fd) }
        sources.append(source)
        source.resume()
        return source
    }

    /// Reads everything available. Data beyond the limit is discarded (the pipe keeps draining so the child is not
    /// stopped by a full pipe before the termination signals arrive).
    private func drain(fd: Int32, isStdout: Bool) {
        guard isStdout ? stdoutSource != nil : stderrSource != nil else { return }
        let limit = isStdout ? limits.stdoutLimit : limits.stderrLimit
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.readChunk, alignment: 1)
        defer { buffer.deallocate() }
        while true {
            let count = read(fd, buffer, Self.readChunk)
            if count > 0 {
                let chunk = Data(bytes: buffer, count: count)
                let overflowed: Bool
                if isStdout {
                    overflowed = Self.append(chunk, to: &stdout, limit: limit, truncated: &stdoutTruncated)
                } else {
                    let kept = stderr.count
                    overflowed = Self.append(chunk, to: &stderr, limit: limit, truncated: &stderrTruncated)
                    if stderr.count > kept { stderrObserver?(Data(stderr[kept...])) }
                }
                if overflowed { terminate() }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            // EOF or a read error: this pipe is done.
            closeReader(isStdout: isStdout, abandoned: false)
            // The child usually closes its pipes by exiting. Do not rely on the exit event alone: with many processes
            // running it is sometimes missed, and the run then waited for the 1 s fallback poll (#87, measured as ~1 s
            // outliers at 8 concurrent queries). Look now, and if the child has not exited yet (it closes its pipes
            // just before it exits), keep looking quickly. checkExit never blocks or reaps.
            checkExit()
            if stdoutSource == nil && stderrSource == nil && exitStatus == nil && waitError == nil {
                startClosedPipesExitPoll()
            }
            tryFinish()
            return
        }
    }

    /// Both pipes are closed but the exit has not been seen: check every `closedPipesPollInterval` until it is. The
    /// child is about to exit, so this runs for a moment only; the timeout still applies.
    private func startClosedPipesExitPoll() {
        let poll = DispatchSource.makeTimerSource(queue: queue)
        let interval = Self.dispatchInterval(Self.closedPipesPollInterval)
        poll.schedule(deadline: .now() + interval, repeating: interval)
        poll.setEventHandler { [self] in checkExit() }
        sources.append(poll)
        poll.resume()
    }

    private func closeReader(isStdout: Bool, abandoned: Bool) {
        if isStdout, let source = stdoutSource {
            source.cancel()
            stdoutSource = nil
            if abandoned { stdoutTruncated = true }
        } else if !isStdout, let source = stderrSource {
            source.cancel()
            stderrSource = nil
            if abandoned { stderrTruncated = true }
        }
    }

    /// Appends up to `limit` bytes in total. Returns true the first time data had to be dropped.
    private static func append(_ chunk: Data, to buffer: inout Data, limit: Int, truncated: inout Bool) -> Bool {
        let room = max(0, limit - buffer.count)
        if chunk.count <= room {
            buffer.append(chunk)
            return false
        }
        buffer.append(chunk.prefix(room))
        defer { truncated = true }
        return !truncated
    }

    /// Detects exit without reaping (`WNOWAIT`): the zombie keeps the pid and process group id reserved, so the
    /// group can still be signalled safely until `tryFinish` reaps it.
    private func checkExit() {
        guard exitStatus == nil, waitError == nil, !finished else { return }
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
            if errno == EINTR { return }
            waitError = errno
        } else if info.si_pid == pid {
            exitStatus = info.si_code == CLD_EXITED ? .exited(code: info.si_status) : .signaled(signal: info.si_status)
        } else {
            return  // still running
        }
        timeoutTimer?.cancel()
        if cancelled {
            abandonPipesAndFinish()
            return
        }
        if stdoutSource == nil && stderrSource == nil {
            tryFinish()
            return
        }
        // Give stray holders of the pipes a short window, then stop waiting for them.
        let drainTimer = DispatchSource.makeTimerSource(queue: queue)
        drainTimer.schedule(deadline: .now() + Self.dispatchInterval(Self.drainWindow))
        drainTimer.setEventHandler { [self] in abandonPipesAndFinish() }
        sources.append(drainTimer)
        drainTimer.resume()
    }

    /// SIGTERM to the group, then SIGKILL to the whole group after the grace period.
    private func terminate() {
        guard !terminating, !finished else { return }
        terminating = true
        signalGroup(SIGTERM)
        let grace = DispatchSource.makeTimerSource(queue: queue)
        grace.schedule(deadline: .now() + Self.dispatchInterval(limits.terminationGracePeriod))
        grace.setEventHandler { [self] in
            if !finished { signalGroup(SIGKILL) }
        }
        sources.append(grace)
        grace.resume()
    }

    /// Only called before the leader is reaped, so `pid` still names our process group. If waiting failed
    /// (e.g. someone else reaped the child), the pid is no longer reserved and nothing is signalled.
    private func signalGroup(_ signal: Int32) {
        guard waitError == nil else { return }
        if kill(-pid, signal) != 0 {
            _ = kill(pid, signal)
        }
    }

    private func abandonPipesAndFinish() {
        guard !finished else { return }
        if stdoutSource != nil || stderrSource != nil {
            signalGroup(SIGKILL)
            closeReader(isStdout: true, abandoned: true)
            closeReader(isStdout: false, abandoned: true)
        }
        tryFinish()
    }

    private func tryFinish() {
        guard !finished, exitStatus != nil || waitError != nil, stdoutSource == nil, stderrSource == nil else {
            return
        }
        finished = true
        stderrObserver = nil  // drop the caller's closure and whatever it captured
        for source in sources { source.cancel() }
        sources.removeAll()
        timeoutTimer = nil

        // A helper in the group may ignore SIGTERM and hold no pipe; finish it off while the zombie leader still
        // reserves the process group id.
        if terminating { signalGroup(SIGKILL) }
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) < 0 && errno == EINTR {}

        let finalOutcome: Result<ProcessResult, Error>
        if cancelled {
            finalOutcome = .failure(CancellationError())
        } else if let waitError {
            finalOutcome = .failure(ProcessRunnerError.waitFailed(errno: waitError))
        } else if let exitStatus {
            finalOutcome = .success(
                ProcessResult(
                    termination: exitStatus,
                    stdout: stdout,
                    stderr: stderr,
                    stdoutTruncated: stdoutTruncated,
                    stderrTruncated: stderrTruncated,
                    timedOut: timedOut,
                    duration: ContinuousClock.now - startedAt
                )
            )
        } else {
            finalOutcome = .failure(ProcessRunnerError.waitFailed(errno: ECHILD))
        }
        stdout = Data()
        stderr = Data()
        if let continuation {
            self.continuation = nil
            continuation.resume(with: finalOutcome)
        } else {
            outcome = finalOutcome
        }
    }

    private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        let clamped = min(max(seconds, 0), 86_400 * 365)  // avoid overflow for absurd limits
        return .nanoseconds(Int(clamped) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}

/// A NULL-terminated `char *[]` that owns its strings.
private final class CStringArray {
    private(set) var pointers: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) {
        pointers = strings.map { strdup($0) } + [nil]
    }

    deinit {
        for pointer in pointers { free(pointer) }
    }
}
