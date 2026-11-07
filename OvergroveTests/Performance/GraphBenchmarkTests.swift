import Foundation
import XCTest

@testable import Overgrove

/// PB-3 and PB-4 inputs for the commit graph (#68, #89) on the bench repository (`scripts/make-bench-repo.sh`).
///
/// - PB-3: the first page (500 commits) read and parsed, nearest-rank p95 of 20 runs after a warm-up.
/// - Paging cost: later pages with `--skip` (git walks the skipped commits again each time) at several depths.
/// - Streaming proxy: the whole history in one process (`-n 100000`), the alternative #89 weighs.
/// - Layout: `GraphEngine` over every page, continuing its state (per-page cost on the main actor).
///
/// Skipped unless `OVERGROVE_BENCH_REPO` points at a bench directory (xcodebuild:
/// `TEST_RUNNER_OVERGROVE_BENCH_REPO=<dir>`). Not part of CI.
final class GraphBenchmarkTests: XCTestCase {
    private func milliseconds(_ duration: Duration) -> Int {
        Int((Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15).rounded())
    }

    private func percentiles(_ samples: [Duration]) -> (Duration, Duration) {
        let sorted = samples.sorted()
        return (sorted[sorted.count / 2], sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1])
    }

    func testPB3_GraphPagesAndLayout() async throws {
        guard let bench = ProcessInfo.processInfo.environment["OVERGROVE_BENCH_REPO"] else {
            throw XCTSkip("set OVERGROVE_BENCH_REPO to a make-bench-repo.sh output directory")
        }
        let root = URL(fileURLWithPath: bench).appendingPathComponent("repo", isDirectory: true)
        let parent = ["HOME": FileManager.default.temporaryDirectory.path]
        let environment = try await GitEnvironment.discover(parentEnvironment: parent)
        let client = GitClient(environment: environment, parentEnvironment: parent)
        let listing = try await client.run(.configList, in: root, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)

        func page(skip: Int, limit: Int) async throws -> (LogParser.GraphPage, Duration) {
            let started = ContinuousClock.now
            let output = try await client.run(.graphPage(skip: skip, limit: limit), in: root, safety: safety)
            let parsed = try LogParser.parseGraph(output.stdout, truncated: output.isTruncated)
            return (parsed, ContinuousClock.now - started)
        }

        var report = ["git \(environment.version), \(ProcessInfo.processInfo.activeProcessorCount) cores"]
        var firstPage: [Duration] = []
        for run in 0..<21 {
            let (_, elapsed) = try await page(skip: 0, limit: 500)
            if run > 0 { firstPage.append(elapsed) }
        }
        let (p50, p95) = percentiles(firstPage)
        report.append("first page (500): p50 \(milliseconds(p50)) ms, p95 \(milliseconds(p95)) ms")
        XCTAssertLessThan(p95, .milliseconds(500), "PB-3 (git and parsing; rendering excluded)")

        let (whole, wholeTime) = try await page(skip: 0, limit: 100_000)
        report.append("whole history in one process: \(whole.commits.count) commits, \(milliseconds(wholeTime)) ms")

        for depth in [500, 10_000, 40_000, 80_000] where depth < whole.commits.count {
            var samples: [Duration] = []
            for _ in 0..<5 { samples.append(try await page(skip: depth, limit: 500).1) }
            let (median, _) = percentiles(samples)
            report.append("page at skip \(depth): median \(milliseconds(median)) ms")
        }

        var state = GraphLayoutState.initial
        var slowest: Duration = .zero
        let layoutStarted = ContinuousClock.now
        for start in stride(from: 0, to: whole.commits.count, by: 500) {
            let slice = Array(whole.commits[start..<min(start + 500, whole.commits.count)])
            let pageStarted = ContinuousClock.now
            state = GraphEngine.layout(slice, continuing: state).state
            slowest = max(slowest, ContinuousClock.now - pageStarted)
        }
        let layoutTotal = ContinuousClock.now - layoutStarted
        report.append(
            "layout of every page: total \(milliseconds(layoutTotal)) ms, slowest page \(milliseconds(slowest)) ms")
        print("PB-3 RESULT\n" + report.joined(separator: "\n"))
    }
}
