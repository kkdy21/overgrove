import Foundation
import XCTest

@testable import Overgrove

/// PERF-03 (PB-3, PB-3b) and PERF-05 (PB-4) for the commit graph (#68, #89; benchmark-plan.md §3).
///
/// - PERF-03 on the bench repository: the first page (500 commits) read and parsed; later pages with `--skip` at
///   several depths; the whole history in one process (the streaming alternative #89 weighs); and `GraphEngine` over
///   every page. A bench repository built without `--commit-graph` is held to PB-3b instead of PB-3.
/// - PERF-05 without a repository: what a page costs the main actor while scrolling (`GraphStore.append` lays the
///   page out), held to one 60 fps frame. The scroll hitch ratio itself needs a UI test (later).
final class GraphBenchmarkTests: XCTestCase {
    private static let pageSize = 500

    /// PERF-03.
    func test_PERF_03_graphFirstPageAndPaging() async throws {
        let root = try PerfRun.benchRepository()
        let parent = PerfRun.isolatedParentEnvironment
        let environment = try await GitEnvironment.discover(parentEnvironment: parent)
        let client = GitClient(environment: environment, parentEnvironment: parent)
        let listing = try await client.run(.configList, in: root, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)

        func page(skip: Int, limit: Int) async throws -> LogParser.GraphPage {
            let output = try await client.run(.graphPage(skip: skip, limit: limit), in: root, safety: safety)
            return try LogParser.parseGraph(output.stdout, truncated: output.isTruncated)
        }

        let hasCommitGraph = Self.hasCommitGraph(root.appendingPathComponent(".git"))
        var report = PerfReport(id: "PERF-03", title: "Graph first page and paging (PB-3, PB-3b)")
        report.note("git \(environment.version), \(ProcessInfo.processInfo.activeProcessorCount) cores")
        report.note("commit-graph: \(hasCommitGraph ? "yes (PB-3)" : "no (PB-3b)")")

        let first = try await PerfSamples.measure(runs: 21) { _ = try await page(skip: 0, limit: Self.pageSize) }
        report.record(
            "first page (\(Self.pageSize))", first, budget: hasCommitGraph ? .milliseconds(500) : .seconds(1),
            budgetLabel: hasCommitGraph ? "500 ms (PB-3)" : "1.0 s (PB-3b)")

        var whole = LogParser.GraphPage(commits: [], isPartial: false)
        let wholeTime = try await PerfSamples.measure(runs: 1, warmUp: 0) {
            whole = try await page(skip: 0, limit: 100_000)
        }
        report.record("whole history in one process (\(whole.commits.count))", value: PerfReport.format(wholeTime.p50))

        for depth in [500, 10_000, 40_000, 80_000] where depth < whole.commits.count {
            let samples = try await PerfSamples.measure(runs: 5, warmUp: 0) {
                _ = try await page(skip: depth, limit: Self.pageSize)
            }
            report.record("page at skip \(depth)", value: "median \(PerfReport.format(samples.p50))")
        }

        let layout = Self.pageLayouts(whole.commits)
        report.record(
            "layout per page (\(layout.samples.count) pages)", layout, budget: Self.frame,
            budgetLabel: "16.7 ms (one frame, PB-4)", usesMaximum: true)
        report.finish()
    }

    /// PERF-05.
    func test_PERF_05_pageLayoutFitsAFrame() throws {
        try PerfRun.requireSynthetic()
        let history = GraphEngineTestSupport.benchHistory(commitCount: 100_000)
        let layout = Self.pageLayouts(history)

        var report = PerfReport(id: "PERF-05", title: "Main-actor cost of one graph page (PB-4 proxy)")
        report.note("synthetic history of \(history.count) commits with the bench repository's lane shape")
        report.note("the scroll hitch ratio needs a UI test (XCUITest, later)")
        report.record(
            "layout per page (\(layout.samples.count) pages)", layout, budget: Self.frame,
            budgetLabel: "16.7 ms (one frame, PB-4)", usesMaximum: true)
        report.finish()

        // An Xcode baseline (`.xcbaseline`) for the deepest pages, where the most lanes have accumulated.
        let tail = Array(history.suffix(Self.pageSize * 4))
        let state = GraphEngine.layout(Array(history.dropLast(tail.count))).state
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            var next = state
            for start in stride(from: 0, to: tail.count, by: Self.pageSize) {
                next = GraphEngine.layout(Array(tail[start..<(start + Self.pageSize)]), continuing: next).state
            }
        }
    }

    /// One 60 fps frame (PB-4): the slowest page's layout must not drop a frame on its own.
    private static let frame: Duration = .microseconds(16_667)

    /// Every page laid out after the previous one, as `GraphStore` appends them.
    private static func pageLayouts(_ commits: [CommitNode]) -> PerfSamples {
        var state = GraphLayoutState.initial
        var samples: [Duration] = []
        for start in stride(from: 0, to: commits.count, by: pageSize) {
            let slice = Array(commits[start..<min(start + pageSize, commits.count)])
            let started = ContinuousClock.now
            state = GraphEngine.layout(slice, continuing: state).state
            samples.append(ContinuousClock.now - started)
        }
        return PerfSamples(samples)
    }

    /// `make-bench-repo.sh --commit-graph` writes one of these (benchmark-plan.md §2).
    private static func hasCommitGraph(_ gitDirectory: URL) -> Bool {
        let info = gitDirectory.appendingPathComponent("objects/info")
        return FileManager.default.fileExists(atPath: info.appendingPathComponent("commit-graph").path)
            || FileManager.default.fileExists(atPath: info.appendingPathComponent("commit-graphs").path)
    }
}
