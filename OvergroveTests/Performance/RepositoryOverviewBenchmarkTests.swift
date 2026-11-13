import Foundation
import XCTest

@testable import Overgrove

/// PERF-01 (PB-1) and PERF-02 (PB-2) on the bench repository's 10 worktrees, through `RepositoryService`
/// (benchmark-plan.md §3). PB-1 (#87): the worktree list and every worktree's status, refs, and stash list.
/// PB-2 (#88): switching between cached worktrees. Results: docs/performance/results/.
///
/// Skipped unless `OVERGROVE_BENCH_REPO` is set (`PerfRun`). The view part of PB-1 and PB-2 (first frame) is not
/// measured here; rendering is excluded.
final class RepositoryOverviewBenchmarkTests: XCTestCase {
    private static let runs = 21  // the first is a warm-up and is dropped (performance-budget.md §1)
    private static let switches = 1000

    /// PERF-01: the first load at several query concurrency caps; the default cap is held to PB-1 (1.0 s p95).
    func test_PERF_01_tenWorktreeOverview() async throws {
        let root = try PerfRun.benchRepository()
        let parent = PerfRun.isolatedParentEnvironment
        let environment = try await GitEnvironment.discoverForTesting(parentEnvironment: parent)
        let repository = Repository(
            rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)

        var report = PerfReport(id: "PERF-01", title: "Ten-worktree overview (PB-1, git layer and parsing)")
        report.note("git \(environment.version), \(ProcessInfo.processInfo.activeProcessorCount) cores")
        for cap in Array(Set([1, 4, GitClient.defaultConcurrency, 10])).sorted() {
            let client = GitClient(environment: environment, parentEnvironment: parent, maximumConcurrency: cap)
            let service = RepositoryService(client: client)
            var worktrees = 0
            let samples = try await PerfSamples.measure(runs: Self.runs) {
                worktrees = try await service.loadOverview(of: repository).entries.count
            }
            XCTAssertEqual(worktrees, 10, "the bench repository has 10 worktrees")
            let isDefault = cap == GitClient.defaultConcurrency
            report.record(
                "query cap \(cap)\(isDefault ? " (default)" : "")", samples, budget: isDefault ? .seconds(1) : nil,
                budgetLabel: isDefault ? "1.0 s (PB-1)" : nil)
        }
        report.finish()
    }

    /// PERF-02: the service part of a cached switch is the memory read (`cachedOverview` + `snapshot(focusing:)`),
    /// held to PB-2 (100 ms). The background status after the switch (`.worktreeSelected`) has its own 35 ms (p95)
    /// git cost (performance-budget.md PB-2), reported for reference.
    func test_PERF_02_cachedWorktreeSwitch() async throws {
        let root = try PerfRun.benchRepository()
        let parent = PerfRun.isolatedParentEnvironment
        let environment = try await GitEnvironment.discoverForTesting(parentEnvironment: parent)
        let service = RepositoryService(client: GitClient(environment: environment, parentEnvironment: parent))
        let repository = Repository(
            rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)
        guard case .success(let loaded) = await service.refresh(repository, trigger: .user)?.result else {
            return XCTFail("the first load failed")
        }
        let paths = loaded.entries.map(\.worktree.path)
        XCTAssertEqual(paths.count, 10)

        var run = 0
        let reads = await PerfSamples.measure(runs: Self.switches, warmUp: 0) {
            let snapshot = await service.cachedOverview(of: repository)?.snapshot(focusing: paths[run % paths.count])
            XCTAssertNotNil(snapshot?.focusedWorktree)
            run += 1
        }
        run = 0
        var failed = false
        let refreshes = await PerfSamples.measure(runs: Self.runs) {
            let refresh = await service.refresh(repository, trigger: .worktreeSelected(paths[run % paths.count]))
            if case .success = refresh?.result {} else { failed = true }
            run += 1
        }
        XCTAssertFalse(failed, "a selection refresh failed")

        var report = PerfReport(id: "PERF-02", title: "Cached worktree switch (PB-2)")
        report.note("git \(environment.version), \(ProcessInfo.processInfo.activeProcessorCount) cores")
        report.record(
            "cached switch, \(reads.samples.count) reads", reads, budget: .milliseconds(100),
            budgetLabel: "100 ms (PB-2, view excluded)")
        // Reported against the status cost the budget assumes, not enforced: it is git time on a shared machine.
        report.record("background selection refresh", refreshes, budgetLabel: "35 ms (status, reference)")
        report.finish()
    }

    /// The compare card under S-02 and S-05 (#581) against the status it follows: after each selection refresh the
    /// status time is new, so the card's comparison (uncommitted changes included) misses the cache every time. This
    /// is the worst case the card adds per refresh of a worktree with WIP changes. Reported, not enforced.
    func test_PERF_10b_compareCardVersusStatus() async throws {
        let root = try PerfRun.benchRepository()
        let parent = PerfRun.isolatedParentEnvironment
        let environment = try await GitEnvironment.discoverForTesting(parentEnvironment: parent)
        let service = RepositoryService(client: GitClient(environment: environment, parentEnvironment: parent))
        let repository = Repository(
            rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)
        guard case .success(let loaded) = await service.refresh(repository, trigger: .user)?.result else {
            return XCTFail("the first load failed")
        }
        // A linked worktree: a lane branch with WIP changes, like an agent's worktree.
        let path = try XCTUnwrap(loaded.entries.first { !$0.worktree.isMain }?.worktree.path)

        var statusSamples: [Duration] = []
        var compareSamples: [Duration] = []
        var failed = false
        for run in 0..<Self.runs {
            let started = ContinuousClock.now
            let refresh = await service.refresh(repository, trigger: .worktreeSelected(path))
            let refreshed = ContinuousClock.now
            let comparison = await service.compare(repository, worktree: path, includeWorkingTree: true)
            let compared = ContinuousClock.now
            if case .success = refresh?.result {} else { failed = true }
            if case .failure = comparison { failed = true }
            guard run > 0 else { continue }  // warm-up
            statusSamples.append(refreshed - started)
            compareSamples.append(compared - refreshed)
        }
        XCTAssertFalse(failed, "a refresh or comparison failed")

        var report = PerfReport(id: "PERF-10b", title: "Compare card per refresh (#581)")
        report.note("git \(environment.version), \(ProcessInfo.processInfo.activeProcessorCount) cores")
        report.record("selection refresh (status)", PerfSamples(statusSamples), budgetLabel: "reference")
        report.record("card comparison, cache miss", PerfSamples(compareSamples), budgetLabel: "reference")
        report.finish()
    }
}
