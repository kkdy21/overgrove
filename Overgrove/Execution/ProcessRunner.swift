import Darwin
import Foundation
import os

// The only place in the app that creates processes (docs/README.md §2.2, ADR-0008).
// Callers (GitClient, GHClient) decide *what* to run; this file decides *how* it runs safely:
//   - posix_spawn with an argument vector and an explicit environment (no shell, nothing inherited)
//   - stdin is /dev/null, so a credential prompt can never block (T12)
//   - POSIX_SPAWN_CLOEXEC_DEFAULT: the child receives only fds 0–2, never the app's other descriptors
//   - the child leads its own process group, so termination reaches helpers it spawned (ssh, remote helpers)
//   - timeouts with SIGTERM → grace period → SIGKILL, output caps, cooperative cancellation (T15)

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
    var stdoutTruncated: Bool
    var stderrTruncated: Bool
    var timedOut: Bool
    var duration: Duration

    var isTruncated: Bool { stdoutTruncated || stderrTruncated }

    /// Exit code 0, complete output, and no timeout.
    var succeeded: Bool { termination == .exited(code: 0) && !timedOut && !isTruncated }
}

enum ProcessRunnerError: Error, Equatable {
    /// The path is not absolute or not an executable file.
    case executableNotFound(path: String)
    /// An argument contains a NUL byte, which would silently truncate it.
    case invalidArgument(index: Int)
    /// An environment key is empty or contains `=` or NUL, or its value contains NUL.
    case invalidEnvironment(key: String)
    case spawnFailed(errno: Int32)
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
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try Self.validate(request)
        try Task.checkCancellation()
        let execution = try ChildProcess.spawn(request)
        onLaunch?(execution.pid)
        execution.start()
        return try await withTaskCancellationHandler {
            try await execution.result()
        } onCancel: {
            execution.cancel()
        }
    }

    private static func validate(_ request: ProcessRequest) throws {
        let path = request.executable.path
        guard path.hasPrefix("/"), access(path, X_OK) == 0 else {
            throw ProcessRunnerError.executableNotFound(path: path)
        }
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

private final class ChildProcess: Sendable {
    private struct State: Sendable {
        var stdout = Data()
        var stderr = Data()
        var stdoutTruncated = false
        var stderrTruncated = false
        var stdoutClosed = false
        var stderrClosed = false
        var waitStatus: Int32?
        var timedOut = false
        var terminating = false
        var cancelled = false
        var delivered = false
        var continuation: CheckedContinuation<ProcessResult, Error>?
        var outcome: Result<ProcessResult, Error>?
    }

    /// After the main process exits, give stray holders of its stdout/stderr this long before killing its group.
    private static let drainWindow: Duration = .milliseconds(500)
    private static let readChunk = 64 * 1024

    let pid: pid_t
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private let limits: ProcessLimits
    private let startedAt: ContinuousClock.Instant
    private let state = OSAllocatedUnfairLock(initialState: State())

    private init(pid: pid_t, stdoutFD: Int32, stderrFD: Int32, limits: ProcessLimits) {
        self.pid = pid
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
        self.limits = limits
        self.startedAt = ContinuousClock.now
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

    // MARK: Run

    func start() {
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async { self.drain(fd: self.stdoutFD, isStdout: true) }
        queue.async { self.drain(fd: self.stderrFD, isStdout: false) }
        queue.async { self.reap() }
        queue.asyncAfter(deadline: .now() + Self.dispatchInterval(limits.timeout)) {
            let fire = self.state.withLock { state -> Bool in
                guard state.waitStatus == nil else { return false }
                state.timedOut = true
                return true
            }
            if fire { self.terminate() }
        }
    }

    func result() async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<ProcessResult, Error>? in
                if let outcome = state.outcome {
                    state.delivered = true
                    return outcome
                }
                state.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func cancel() {
        state.withLock { $0.cancelled = true }
        terminate()
    }

    // MARK: Internals

    /// SIGTERM to the process group, then SIGKILL after the grace period if the main process is still alive.
    private func terminate() {
        let first = state.withLock { state -> Bool in
            guard !state.terminating, state.waitStatus == nil else { return false }
            state.terminating = true
            return true
        }
        guard first else { return }
        signalGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.dispatchInterval(limits.terminationGracePeriod)) {
            let alive = self.state.withLock { $0.waitStatus == nil }
            if alive { self.signalGroup(SIGKILL) }
        }
    }

    private func signalGroup(_ signal: Int32) {
        if kill(-pid, signal) != 0 {
            _ = kill(pid, signal)
        }
    }

    private func drain(fd: Int32, isStdout: Bool) {
        let limit = isStdout ? limits.stdoutLimit : limits.stderrLimit
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.readChunk, alignment: 1)
        defer { buffer.deallocate() }
        while true {
            let count = read(fd, buffer, Self.readChunk)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            let chunk = Data(bytes: buffer, count: count)
            let overflowed = state.withLock { state -> Bool in
                guard isStdout else {
                    return Self.append(chunk, to: &state.stderr, limit: limit, truncated: &state.stderrTruncated)
                }
                return Self.append(chunk, to: &state.stdout, limit: limit, truncated: &state.stdoutTruncated)
            }
            if overflowed { terminate() }
        }
        close(fd)
        state.withLock { state in
            if isStdout { state.stdoutClosed = true } else { state.stderrClosed = true }
        }
        finishIfDone()
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

    private func reap() {
        var rawStatus: Int32 = 0
        while waitpid(pid, &rawStatus, 0) < 0 && errno == EINTR {}
        let status = rawStatus
        state.withLock { $0.waitStatus = status }
        // Helpers the child left behind may still hold the pipes open; do not wait for them forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.dispatchInterval(Self.drainWindow)) {
            let pending = self.state.withLock { !$0.stdoutClosed || !$0.stderrClosed }
            if pending { _ = kill(-self.pid, SIGKILL) }
        }
        finishIfDone()
    }

    private func finishIfDone() {
        let delivery = state.withLock {
            state -> (CheckedContinuation<ProcessResult, Error>, Result<ProcessResult, Error>)? in
            guard state.outcome == nil, state.stdoutClosed, state.stderrClosed, let status = state.waitStatus else {
                return nil
            }
            let outcome: Result<ProcessResult, Error>
            if state.cancelled {
                outcome = .failure(CancellationError())
            } else {
                outcome = .success(
                    ProcessResult(
                        termination: Self.termination(from: status),
                        stdout: state.stdout,
                        stderr: state.stderr,
                        stdoutTruncated: state.stdoutTruncated,
                        stderrTruncated: state.stderrTruncated,
                        timedOut: state.timedOut,
                        duration: ContinuousClock.now - startedAt
                    )
                )
            }
            state.outcome = outcome
            guard let continuation = state.continuation, !state.delivered else { return nil }
            state.continuation = nil
            state.delivered = true
            return (continuation, outcome)
        }
        if let (continuation, outcome) = delivery {
            continuation.resume(with: outcome)
        }
    }

    /// Decodes a `waitpid` status (the WIFEXITED/WEXITSTATUS/WTERMSIG macros are not imported into Swift).
    private static func termination(from status: Int32) -> ProcessTermination {
        let low = status & 0x7f
        return low == 0 ? .exited(code: (status >> 8) & 0xff) : .signaled(signal: low)
    }

    private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
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
