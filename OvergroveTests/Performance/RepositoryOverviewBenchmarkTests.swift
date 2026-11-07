import Foundation
import XCTest

@testable import Overgrove

/// PB-1 (performance-budget.md §2): the worktree list and every worktree's status, refs, and stash list for the bench
/// repository's 10 worktrees, through `RepositoryService` (#87). Results: docs/performance/results/.
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
        let inspector = GitClient(environment: environment, parentEnvironment: parent)
        let listing = try await inspector.run(.configList, in: root, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)
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
                let overview = try await service.loadOverview(of: repository, safety: safety)
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

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15).rounded())
    }
}
