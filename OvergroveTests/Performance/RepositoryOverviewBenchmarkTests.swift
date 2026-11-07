import Foundation
import XCTest

@testable import Overgrove

/// PB-1 and PB-2 (performance-budget.md §2) on the bench repository's 10 worktrees, through `RepositoryService`.
/// PB-1 (#87): the worktree list and every worktree's status, refs, and stash list. PB-2 (#88): switching between
/// cached worktrees. Results: docs/performance/results/.
///
/// Skipped unless `OVERGROVE_BENCH_REPO` points at a `scripts/make-bench-repo.sh` output directory; with xcodebuild,
/// pass it as `TEST_RUNNER_OVERGROVE_BENCH_REPO=<dir>`. Not part of CI: the bench repository takes minutes to build.
final class RepositoryOverviewBenchmarkTests: XCTestCase {
    private static let runs = 21  // the first is a warm-up and is dropped (performance-budget.md §1)

    func testPB1_TenWorktreesOverview() async throws {
        guard let bench = ProcessInfo.processInfo.environment["OVERGROVE_BENCH_REPO"] else {
            throw XCTSkip("set OVERGROVE_BENCH_REPO to a make-bench-repo.sh output directory")
        }
        let root = URL(fileURLWithPath: bench).appendingPathComponent("repo", isDirectory: true)
        let parent = ["HOME": FileManager.default.temporaryDirectory.path]
        let environment = try await GitEnvironment.discover(parentEnvironment: parent)
        let repository = Repository(
            rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)

        var report = ["git \(environment.version), \(ProcessInfo.processInfo.activeProcessorCount) cores"]
        for cap in Array(Set([1, 4, GitClient.defaultConcurrency, 10])).sorted() {
            let client = GitClient(environment: environment, parentEnvironment: parent, maximumConcurrency: cap)
            let service = RepositoryService(client: client)
            var samples: [Duration] = []
            var worktrees = 0
            for run in 0..<Self.runs {
                let started = ContinuousClock.now
                let overview = try await service.loadOverview(of: repository)
                let elapsed = ContinuousClock.now - started
                worktrees = overview.entries.count
                if run > 0 { samples.append(elapsed) }
            }
            XCTAssertEqual(worktrees, 10, "the bench repository has 10 worktrees")
            samples.sort()
            let p50 = samples[samples.count / 2]
            let p95 = samples[Int((Double(samples.count) * 0.95).rounded(.up)) - 1]  // nearest rank
            report.append("cap \(cap): p50 \(Self.milliseconds(p50)) ms, p95 \(Self.milliseconds(p95)) ms")
            if cap == GitClient.defaultConcurrency {
                XCTAssertLessThan(p95, .seconds(1), "PB-1 budget (git layer and parsing only; rendering excluded)")
            }
        }
        print("PB-1 RESULT\n" + report.joined(separator: "\n"))
    }

    /// PB-2 (performance-budget.md §2): switching between cached worktrees. The service part is the memory read
    /// (`cachedOverview` + `snapshot(focusing:)`); the view update is measured once #65 draws the list. The background
    /// status after the switch (`.worktreeSelected`) has its own 35 ms (p95) git budget.
    func testPB2_CachedWorktreeSwitch() async throws {
        guard let bench = ProcessInfo.processInfo.environment["OVERGROVE_BENCH_REPO"] else {
            throw XCTSkip("set OVERGROVE_BENCH_REPO to a make-bench-repo.sh output directory")
        }
        let root = URL(fileURLWithPath: bench).appendingPathComponent("repo", isDirectory: true)
        let parent = ["HOME": FileManager.default.temporaryDirectory.path]
        let environment = try await GitEnvironment.discover(parentEnvironment: parent)
        let service = RepositoryService(client: GitClient(environment: environment, parentEnvironment: parent))
        let repository = Repository(
            rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)
        guard case .success(let loaded) = await service.refresh(repository, trigger: .user)?.result else {
            return XCTFail("the first load failed")
        }
        let paths = loaded.entries.map(\.worktree.path)
        XCTAssertEqual(paths.count, 10)

        var reads: [Duration] = []
        for run in 0..<Self.switches {
            let started = ContinuousClock.now
            let overview = await service.cachedOverview(of: repository)
            let snapshot = overview?.snapshot(focusing: paths[run % paths.count])
            reads.append(ContinuousClock.now - started)
            XCTAssertNotNil(snapshot?.focusedWorktree)
        }
        var backgrounds: [Duration] = []
        for run in 0..<Self.runs {
            let started = ContinuousClock.now
            let refresh = await service.refresh(repository, trigger: .worktreeSelected(paths[run % paths.count]))
            let elapsed = ContinuousClock.now - started
            guard case .success = refresh?.result else { return XCTFail("selection refresh failed") }
            if run > 0 { backgrounds.append(elapsed) }
        }
        let (readP50, readP95) = Self.percentiles(reads)
        let (statusP50, statusP95) = Self.percentiles(backgrounds)
        XCTAssertLessThan(readP95, .milliseconds(100), "PB-2 budget (memory read; view update excluded)")
        print(
            """
            PB-2 RESULT
            git \(environment.version), \(ProcessInfo.processInfo.activeProcessorCount) cores
            cached switch (\(reads.count) reads): p50 \(Self.microseconds(readP50)) µs, p95 \(Self.microseconds(readP95)) µs
            background selection refresh (\(backgrounds.count) runs): p50 \(Self.milliseconds(statusP50)) ms, \
            p95 \(Self.milliseconds(statusP95)) ms
            """)
    }

    private static let switches = 1000

    /// Median and nearest-rank 95th percentile.
    private static func percentiles(_ samples: [Duration]) -> (Duration, Duration) {
        let sorted = samples.sorted()
        return (sorted[sorted.count / 2], sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1])
    }

    private static func microseconds(_ duration: Duration) -> Int {
        Int((Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12).rounded())
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15).rounded())
    }
}
