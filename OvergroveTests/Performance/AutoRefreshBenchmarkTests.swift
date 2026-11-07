import Foundation
import XCTest

@testable import Overgrove

/// PERF-10 (#119, #163): auto refresh during an event storm. A tool rewrites thousands of files in a worktree (an
/// ignored dependency folder, like `npm install` or an agent's build) while the window is visible. The watcher must
/// keep the number of refreshes, and so of `git status` runs, within the debounce and re-run gap.
///
/// Real FSEvents, the real `AutoRefreshController`, and the real `RepositoryService` on the normal fixture, with a git
/// stand-in that counts subcommands. Skipped unless `OVERGROVE_PERF=1` (`PerfRun`).
@MainActor
final class AutoRefreshBenchmarkTests: XCTestCase {
    private static let files = 6_000
    private static let stormSeconds = 8.0

    func testPERF10_EventStormKeepsStatusRunsBounded() async throws {
        try PerfRun.requireSynthetic()
        let executables = try TestExecutables()
        defer { executables.remove() }
        let markers = executables.directory.appendingPathComponent("markers", isDirectory: true)
        let fixture = try await FixtureRepo.make(malicious: false)
        defer { fixture.remove() }
        let context = try await IntegrationContext.make(fixture: fixture)
        let gated = try executables.gatedGit(forwardingTo: context.environment.executable, markers: markers)
        FileManager.default.createFile(atPath: markers.appendingPathComponent("release").path, contents: nil)
        let service = RepositoryService(
            client: GitClient(
                environment: GitEnvironment(executable: gated, version: context.environment.version),
                parentEnvironment: fixture.environment),
            sleep: { _ in })
        guard case .success(let loaded) = await service.refresh(context.repository, trigger: .user)?.result else {
            return XCTFail("the first load failed")
        }
        let classifier = try XCTUnwrap(
            FileChangeClassifier(listing: WorktreeListing(overview: loaded), repository: context.repository))
        let statusRuns = { () -> Int in
            let log =
                (try? String(contentsOf: markers.appendingPathComponent("invocations.log"), encoding: .utf8)) ?? ""
            return log.split(separator: "\n").filter { $0 == "status" }.count
        }
        let baseline = statusRuns()

        let controller = AutoRefreshController()
        var durations: [Duration] = []
        controller.request = { [weak controller] change in
            let started = ContinuousClock.now
            Task { @MainActor in
                let result = await service.refresh(
                    context.repository,
                    trigger: .filesChanged(
                        worktrees: change.worktrees, refs: change.refs, worktreeList: change.worktreeList))
                durations.append(ContinuousClock.now - started)
                let outcome: AutoRefreshController.LoadOutcome =
                    switch result?.result {
                    case .success: .succeeded
                    case .failure: .failed
                    case nil: .superseded
                    }
                controller?.loadFinished(
                    .filesChanged(worktrees: change.worktrees, refs: change.refs, worktreeList: change.worktreeList),
                    outcome: outcome)
            }
            return true
        }
        controller.update(classifier)
        controller.setVisible(true)
        try await Task.sleep(for: .seconds(1))

        let childCPUBefore = Self.childCPUSeconds()
        let start = ContinuousClock.now
        let storm = fixture.repository.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: storm, withIntermediateDirectories: true)
        let batches = 40
        for batch in 0..<batches {
            for index in 0..<(Self.files / batches) {
                try Data("x\(batch)-\(index)\n".utf8).write(
                    to: storm.appendingPathComponent("f\(batch)-\(index).js"))
            }
            try await Task.sleep(for: .milliseconds(Int(Self.stormSeconds * 1000) / batches))
        }
        // Let the last batch settle and the final refresh run.
        try await Task.sleep(for: .seconds(6))
        controller.setVisible(false)
        let elapsed = ContinuousClock.now - start
        let childCPU = Self.childCPUSeconds() - childCPUBefore

        let requests = controller.requestCount
        let statuses = statusRuns() - baseline
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        // Debounce 1 s, gap at least 2 s: at most one request per 2 s, plus the one after the storm.
        let bound = Int((elapsedSeconds / 2).rounded(.up)) + 1
        let report = """
            PERF-10 RESULT (\(Self.files) files over \(Self.stormSeconds) s, \(classifier.worktrees.count) watched worktrees)
            elapsed \(String(format: "%.1f", elapsedSeconds)) s, requests \(requests) (bound \(bound)), status runs \(statuses)
            refresh durations: \(durations.map { "\($0.components.attoseconds / 1_000_000_000_000_000 + $0.components.seconds * 1000) ms" }.joined(separator: ", "))
            git CPU (children): \(String(format: "%.2f", childCPU)) s = \(String(format: "%.1f", childCPU / elapsedSeconds * 100)) % of one core
            """
        print(report)
        if let directory = PerfRun.reportDirectory {
            try report.write(to: directory.appendingPathComponent("PERF-10.md"), atomically: true, encoding: .utf8)
        }
        XCTAssertGreaterThan(requests, 0, "the storm was seen")
        XCTAssertLessThanOrEqual(requests, bound)
        XCTAssertEqual(statuses, requests, "one status per request: only the changed worktree")
    }

    /// User and system CPU time of finished child processes (the git runs).
    private static func childCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_CHILDREN, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
