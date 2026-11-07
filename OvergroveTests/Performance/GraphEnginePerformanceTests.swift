import XCTest

@testable import Overgrove

/// GRA-09 / PERF-04: lane layout for 100,000 commits without UI (test-strategy.md §4.2, benchmark-plan.md §3).
///
/// The history has the bench repository's shape (about a dozen lanes alive at once). There is no committed baseline;
/// record one locally with Xcode (`.xcbaseline`) when changing GraphEngine, as benchmark-plan.md §6 describes.
final class GraphEnginePerformanceTests: XCTestCase {
    private static let commitCount = 100_000
    private static let pageSize = 500

    // Built once: generating 100k commits costs more than laying them out.
    private static let history = GraphEngineTestSupport.benchHistory(commitCount: commitCount)

    func test_GRA_09_layoutOfOneHundredThousandCommits() {
        let history = Self.history
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        var rowCount = 0
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            rowCount = GraphEngine.layout(history).rows.count
        }
        XCTAssertEqual(rowCount, history.count)
    }

    func test_GRA_09_pagedLayoutMatchesSinglePass() {
        let history = Self.history
        let whole = GraphEngine.layout(history)

        var state = GraphLayoutState.initial
        var rows: [GraphRow] = []
        rows.reserveCapacity(history.count)
        for start in stride(from: 0, to: history.count, by: Self.pageSize) {
            let page = GraphEngine.layout(
                Array(history[start..<min(start + Self.pageSize, history.count)]),
                continuing: state
            )
            rows += page.rows
            state = page.state
        }

        XCTAssertEqual(rows, whole.rows)
        XCTAssertEqual(state, whole.state)
        GraphEngineTestSupport.assertWellFormed(whole.rows)
    }
}
