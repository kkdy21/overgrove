import Foundation

/// Starts glab and gt the same way (ADR-0026 §4): through `ProcessRunner`, in an app-owned empty folder (never a
/// repository), with the caller's allowlisted environment and limits. Output over a limit fails rather than being read
/// in part. `GLClient` and `GTClient` turn `Failure` into their own errors.
struct ForgeCLILauncher: Sendable {
    enum Failure: Error, Equatable {
        case notInstalled
        case launchFailed(errno: Int32)
        case timeout(seconds: Int)
        case outputTruncated
        case cancelled
    }

    let runner: ProcessRunner
    let neutralDirectory: URL
    let limits: ProcessLimits

    /// Runs `executable` with `arguments` and `environment` (already the complete child environment).
    func run(executable: URL, arguments: [String], environment: [String: String]) async throws(Failure)
        -> ProcessResult
    {
        try? FileManager.default.createDirectory(
            at: neutralDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let request = ProcessRequest(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: neutralDirectory,
            limits: limits
        )
        let result: ProcessResult
        do {
            result = try await runner.run(request)
        } catch ProcessRunnerError.executableNotFound {
            throw .notInstalled
        } catch ProcessRunnerError.spawnFailed(let code), ProcessRunnerError.waitFailed(let code) {
            throw .launchFailed(errno: code)
        } catch ProcessRunnerError.invalidArgument, ProcessRunnerError.invalidEnvironment {
            // Validated types cannot carry a NUL byte; refuse rather than run something else.
            throw .launchFailed(errno: EINVAL)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            // The runner reports nothing else today; anything new it adds is a failure, never a result.
            throw .launchFailed(errno: EINVAL)
        }
        if result.timedOut { throw .timeout(seconds: Int(limits.timeout.components.seconds)) }
        if result.stdoutTruncated { throw .outputTruncated }
        return result
    }

    /// The code a failed process reports: its exit code, or 128 + the signal that stopped it.
    static func failureCode(_ termination: ProcessTermination) -> Int32 {
        termination.exitCode ?? (termination.signal.map { 128 + $0 } ?? -1)
    }
}
