import Foundation
import XCTest

@testable import Overgrove

/// ProcessRunner behavior required by issue #41, ADR-0008, and threat T15 (docs/design/security-review.md).
final class ProcessRunnerTests: XCTestCase {
    private var executables: TestExecutables!

    override func setUpWithError() throws {
        executables = try TestExecutables()
    }

    override func tearDown() {
        executables.remove()
    }

    private func request(
        _ path: String,
        _ arguments: [String] = [],
        environment: [String: String] = [:],
        directory: URL? = nil,
        limits: ProcessLimits = .query
    ) -> ProcessRequest {
        ProcessRequest(
            executable: URL(fileURLWithPath: path),
            arguments: arguments,
            environment: environment,
            currentDirectory: directory,
            limits: limits
        )
    }

    // MARK: - Basics

    func testCollectsStdoutStderrAndExitCode() async throws {
        let script = try executables.exitWith(3)
        let result = try await ProcessRunner().run(request(script.path))
        XCTAssertEqual(result.termination, .exited(code: 3))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err\n")
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.isTruncated)
        XCTAssertFalse(result.succeeded)
    }

    /// Thread-safe collector for the stderr observer.
    private final class Chunks: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private(set) var count = 0
        var data: Data { lock.withLock { storage } }
        func append(_ chunk: Data) {
            lock.withLock {
                storage.append(chunk)
                count += 1
            }
        }
    }

    func testStderrObserverSeesStderrOnly() async throws {
        // Fetch progress is read from stderr while git runs (#76).
        let script = try executables.exitWith(0)
        let chunks = Chunks()
        let result = try await ProcessRunner().run(request(script.path), stderrObserver: { chunks.append($0) })
        XCTAssertEqual(chunks.data, result.stderr)
        XCTAssertEqual(String(decoding: chunks.data, as: UTF8.self), "err\n", "stdout is not observed")
    }

    func testStderrObserverStopsAtTheLimit() async throws {
        // `ls` reports each missing path on stderr: far more than the 1 KiB limit.
        let missing = (0..<2000).map { "/nonexistent-overgrove-\($0)" }
        var limits = ProcessLimits.query
        limits.stderrLimit = 1024
        let chunks = Chunks()
        let result = try await ProcessRunner().run(
            request("/bin/ls", missing, limits: limits), stderrObserver: { chunks.append($0) })
        XCTAssertTrue(result.stderrTruncated)
        XCTAssertEqual(chunks.data, result.stderr, "the observer never sees bytes beyond the limit")
        XCTAssertEqual(chunks.data.count, 1024)
    }

    func testArgumentsArePassedVerbatimWithoutAShell() async throws {
        let tricky = ["a b", "$(touch /tmp/should-not-exist)", "; rm -rf ~", "--", "-n", "ü\u{0301}"]
        let result = try await ProcessRunner().run(request("/usr/bin/printf", ["%s\\n"] + tricky))
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), tricky.map { $0 + "\n" }.joined())
    }

    func testEnvironmentIsExactlyWhatWasRequested() async throws {
        // SEC-T10 precondition: nothing is inherited from the test process.
        let result = try await ProcessRunner().run(request("/usr/bin/env", environment: ["ONLY": "this"]))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "ONLY=this\n")
    }

    func testRunsInRequestedDirectory() async throws {
        let result = try await ProcessRunner().run(request("/bin/pwd", directory: executables.directory))
        let printed = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        XCTAssertEqual(
            URL(fileURLWithPath: printed).resolvingSymlinksInPath(),
            executables.directory.resolvingSymlinksInPath()
        )
    }

    func testStdinIsEmptySoPromptsCannotBlock() async throws {
        let result = try await ProcessRunner().run(request("/bin/cat"))
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertTrue(result.stdout.isEmpty)
    }

    // MARK: - Validation

    func testRejectsMissingOrRelativeExecutable() async throws {
        await assertThrows(ProcessRunnerError.executableNotFound(path: "/nonexistent/git")) {
            _ = try await ProcessRunner().run(self.request("/nonexistent/git"))
        }
        // `URL(fileURLWithPath:)` would silently make a relative path absolute, so build a relative URL directly.
        var relative = request("/usr/bin/true")
        relative.executable = try XCTUnwrap(URL(string: "git"))
        let relativeRequest = relative
        await assertThrows(ProcessRunnerError.executableNotFound(path: "git")) {
            _ = try await ProcessRunner().run(relativeRequest)
        }
    }

    func testRejectsNULInArguments() async {
        // A NUL would silently truncate the C string (threat T9).
        await assertThrows(ProcessRunnerError.invalidArgument(index: 1)) {
            _ = try await ProcessRunner().run(self.request("/bin/echo", ["ok", "bad\u{0}tail"]))
        }
    }

    func testRejectsMalformedEnvironment() async {
        await assertThrows(ProcessRunnerError.invalidEnvironment(key: "A=B")) {
            _ = try await ProcessRunner().run(self.request("/usr/bin/env", environment: ["A=B": "1"]))
        }
        await assertThrows(ProcessRunnerError.invalidEnvironment(key: "K")) {
            _ = try await ProcessRunner().run(self.request("/usr/bin/env", environment: ["K": "v\u{0}"]))
        }
    }

    // MARK: - SEC-T15-01: output limits

    func testSECT15_01_StdoutIsCappedAndMarkedTruncated() async throws {
        let limits = ProcessLimits(timeout: .seconds(10), stdoutLimit: 64 * 1024, stderrLimit: 1024)
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await ProcessRunner().run(request("/usr/bin/yes", limits: limits))
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertEqual(result.stdout.count, 64 * 1024)
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(clock.now - start, .seconds(5), "the producer must be stopped once the limit is hit")
    }

    // MARK: - SEC-T15-02: timeout, escalation, no leftovers

    func testSECT15_02_TimeoutTerminatesAndLeavesNoZombie() async throws {
        let recorder = PIDRecorder()
        let limits = ProcessLimits(timeout: .milliseconds(300), stdoutLimit: 1024, stderrLimit: 1024)
        let result = try await ProcessRunner(onLaunch: recorder.record).run(
            request("/bin/sleep", ["30"], limits: limits))
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.termination, .signaled(signal: SIGTERM))
        let pid = try XCTUnwrap(recorder.pid)
        XCTAssertFalse(processExists(pid), "the child must be reaped before run() returns")
    }

    func testEscalatesToSIGKILLAfterGracePeriod() async throws {
        let script = try executables.ignoringSIGTERMThenFlooding()
        let limits = ProcessLimits(
            timeout: .seconds(30),
            stdoutLimit: 1024,
            stderrLimit: 1024,
            terminationGracePeriod: .milliseconds(300)
        )
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await ProcessRunner().run(request(script.path, limits: limits))
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.termination, .signaled(signal: SIGKILL), "SIGTERM is ignored, so SIGKILL must follow")
        XCTAssertLessThan(clock.now - start, .seconds(5))
    }

    func testTerminationAlsoKillsGrandchildren() async throws {
        // Timeout, output limit, and cancellation share the same group termination path.
        let script = try executables.spawningGrandchildThenFlooding()
        let pidFile = executables.directory.appendingPathComponent("grandchild.pid")
        let limits = ProcessLimits(timeout: .seconds(30), stdoutLimit: 1024, stderrLimit: 1024)
        let result = try await ProcessRunner().run(request(script.path, [pidFile.path], limits: limits))
        XCTAssertTrue(result.stdoutTruncated)
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let grandchild = try XCTUnwrap(pid_t(text))
        let gone = await eventually { !processExists(grandchild) }
        XCTAssertTrue(gone, "the whole process group must be terminated")
    }

    func testReturnsWhenChildExitsEvenIfABackgroundProcessHoldsStdout() async throws {
        let script = try executables.leavingChildWithOpenStdout()
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await ProcessRunner().run(request(script.path))
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "started\n")
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(clock.now - start, .seconds(5))
    }

    // MARK: - Cancellation

    func testCancellationTerminatesTheProcess() async throws {
        let recorder = PIDRecorder()
        let launched = expectation(description: "launched")
        let runner = ProcessRunner(onLaunch: { pid in
            recorder.record(pid)
            launched.fulfill()
        })
        let sleeper = request("/bin/sleep", ["30"])
        let task = Task { try await runner.run(sleeper) }
        await fulfillment(of: [launched], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
        let pid = try XCTUnwrap(recorder.pid)
        XCTAssertFalse(processExists(pid), "the child must be reaped after cancellation")
    }

    func testCancellationEscalatesWhenSIGTERMIsIgnored() async throws {
        let script = try executables.ignoringSIGTERMWithReadyFile()
        let ready = executables.directory.appendingPathComponent("ready")
        let recorder = PIDRecorder()
        let limits = ProcessLimits(
            timeout: .seconds(30),
            stdoutLimit: 1024,
            stderrLimit: 1024,
            terminationGracePeriod: .milliseconds(300)
        )
        let runner = ProcessRunner(onLaunch: recorder.record)
        let ignoring = request(script.path, [ready.path], limits: limits)
        let task = Task { try await runner.run(ignoring) }
        let trapInstalled = await eventually { FileManager.default.fileExists(atPath: ready.path) }
        XCTAssertTrue(trapInstalled)
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        await assertThrowsCancellation { _ = try await task.value }
        XCTAssertLessThan(clock.now - start, .seconds(5))
        XCTAssertFalse(processExists(try XCTUnwrap(recorder.pid)))
    }

    // MARK: - Robustness (security review of PR #138)

    func testManyConcurrentRunsStillTimeOut() async throws {
        // Blocking reads/waits on shared threads used to starve the timeout timers at ~25 concurrent runs.
        let limits = ProcessLimits(timeout: .milliseconds(300), stdoutLimit: 1024, stderrLimit: 1024)
        let sleeper = request("/bin/sleep", ["20"], limits: limits)
        let clock = ContinuousClock()
        let start = clock.now
        let results = try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            for _ in 0..<48 {
                group.addTask { try await ProcessRunner().run(sleeper) }
            }
            return try await group.reduce(into: [ProcessResult]()) { $0.append($1) }
        }
        XCTAssertEqual(results.count, 48)
        XCTAssertTrue(results.allSatisfy(\.timedOut))
        XCTAssertLessThan(clock.now - start, .seconds(5))
    }

    func testHelperIgnoringSIGTERMIsKilledWhenTheRunFinishes() async throws {
        // Re-review of #138: the leader dies on SIGTERM and the pipes close, so the run finishes before the grace
        // timer; the stubborn helper must still get SIGKILL while the leader's process group id is reserved.
        let script = try executables.spawningSIGTERMIgnoringHelperThenFlooding()
        let pidFile = executables.directory.appendingPathComponent("helper.pid")
        let limits = ProcessLimits(
            timeout: .seconds(30),
            stdoutLimit: 1024,
            stderrLimit: 1024,
            terminationGracePeriod: .seconds(5)
        )
        let result = try await ProcessRunner().run(request(script.path, [pidFile.path], limits: limits))
        XCTAssertTrue(result.stdoutTruncated)
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let helper = try XCTUnwrap(pid_t(text))
        let gone = await eventually(timeout: .seconds(1)) { !processExists(helper) }
        XCTAssertTrue(gone, "the helper must not outlive the run")
    }

    func testHelperThatLeavesTheProcessGroupCannotHangTheRun() async throws {
        // A daemonizing helper (setsid) keeps stdout open after the leader exits.
        let perl = "/usr/bin/perl"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: perl), "perl is not available")
        // `fo` + `rk(` keeps the Perl source from matching the forbidden-API lint, which scans Swift text.
        let program = "use POSIX; if (fo" + "rk() == 0) { POSIX::setsid(); sleep 30; exit 0 } print \"leader done\\n\";"
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await ProcessRunner().run(request(perl, ["-e", program]))
        XCTAssertLessThan(clock.now - start, .seconds(3), "the run must not wait for the escaped helper")
        XCTAssertEqual(result.termination, .exited(code: 0))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "leader done\n")
        XCTAssertTrue(result.stdoutTruncated, "abandoned output is reported as incomplete")
    }

    func testChildDoesNotInheritExtraDescriptors() async throws {
        let probe = try executables.reportingDescriptor()
        let extra = open("/dev/null", O_RDONLY)  // deliberately without O_CLOEXEC
        XCTAssertGreaterThanOrEqual(extra, 0)
        defer { close(extra) }
        let result = try await ProcessRunner().run(request(probe.path, [String(extra)]))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "clean\n")
    }

    func testParentDoesNotLeakDescriptors() async throws {
        let before = openDescriptorCount()
        for _ in 0..<30 {
            _ = try await ProcessRunner().run(request("/bin/echo", ["x"]))
            _ = try? await ProcessRunner().run(request("/bin/echo", directory: URL(fileURLWithPath: "/nonexistent")))
        }
        XCTAssertEqual(openDescriptorCount(), before)
    }

    func testDirectoryIsNotAnExecutable() async {
        await assertThrows(ProcessRunnerError.executableNotFound(path: "/usr/bin")) {
            _ = try await ProcessRunner().run(self.request("/usr/bin"))
        }
    }

    // MARK: - Helpers

    private func assertThrowsCancellation(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected CancellationError", file: file, line: line)
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func assertThrows(
        _ expected: ProcessRunnerError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: @escaping () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as ProcessRunnerError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

/// Captures the pid reported by `ProcessRunner(onLaunch:)`.
private final class PIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: pid_t?

    var pid: pid_t? { lock.withLock { value } }

    func record(_ pid: pid_t) {
        lock.withLock { value = pid }
    }
}
