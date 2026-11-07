import XCTest

@testable import Overgrove

/// GRA-01…08 (test-strategy.md §4.2, ADR-0010). GRA-09 is in `Performance/GraphEnginePerformanceTests.swift`.
///
/// Histories are listed newest first, as `git log --date-order` prints them. A row's `incoming` segments run from the
/// row above (`from`) to this row (`to`); the expected values below are in the engine's documented order: open lanes by
/// column, then merge edges from the node above.
final class GraphEngineTests: XCTestCase {
    private typealias Support = GraphEngineTestSupport

    private func commit(_ number: Int, _ parents: Int...) -> CommitNode { Support.commit(number, parents: parents) }
    private func commit(_ number: Int, parents: [Int]) -> CommitNode { Support.commit(number, parents: parents) }
    private func seg(_ from: Int, _ to: Int, color: Int) -> GraphSegment { Support.segment(from, to, color: color) }

    private func layout(_ commits: [CommitNode]) -> GraphLayoutPage { GraphEngine.layout(commits) }

    // MARK: - GRA-01

    func test_GRA_01_linearHistoryUsesOneLane() {
        let page = layout([commit(3, 2), commit(2, 1), commit(1)])

        XCTAssertEqual(page.rows.map(\.oid), [Support.oid(3), Support.oid(2), Support.oid(1)])
        XCTAssertEqual(page.rows.map(\.column), [0, 0, 0])
        XCTAssertEqual(page.rows.map(\.colorIndex), [0, 0, 0])
        XCTAssertEqual(page.rows.map(\.incoming), [[], [seg(0, 0, color: 0)], [seg(0, 0, color: 0)]])
        XCTAssertEqual(page.state, .initial, "the root closes the only lane")
        XCTAssertEqual(page.state.pendingSegments, [])
    }

    func test_GRA_01_emptyInputLeavesStateUntouched() {
        let first = layout([commit(2, 1)])
        let next = GraphEngine.layout([], continuing: first.state)

        XCTAssertEqual(next.rows, [])
        XCTAssertEqual(next.state, first.state)
    }

    // MARK: - GRA-02

    func test_GRA_02_mergeOpensLaneForSecondParentAndBranchRejoinsAtForkPoint() {
        // 4 merges feature 3 into main 2; both come from 1.
        let page = layout([commit(4, 2, 3), commit(3, 1), commit(2, 1), commit(1)])

        XCTAssertEqual(page.rows.map(\.column), [0, 1, 0, 0])
        XCTAssertEqual(page.rows.map(\.colorIndex), [0, 1, 0, 0])
        XCTAssertEqual(
            page.rows.map(\.incoming),
            [
                [],
                // Merge edge: leaves the merge node and lands on the new lane, in that lane's color.
                [seg(0, 0, color: 0), seg(0, 1, color: 1)],
                [seg(0, 0, color: 0), seg(1, 1, color: 1)],
                // Branch edge: the feature lane curves into its parent in the feature lane's color.
                [seg(0, 0, color: 0), seg(1, 0, color: 1)],
            ]
        )
        XCTAssertEqual(page.state, .initial)
        Support.assertWellFormed(page.rows)
    }

    func test_GRA_02_mergeParentAlreadyOnALaneJoinsThatLane() {
        // 5 is a feature tip on lane 0. Merge 4 (lane 1) brings in 5's parent 3, which lane 0 already waits for.
        let page = layout([commit(5, 3), commit(4, 2, 3), commit(3, 1), commit(2, 1), commit(1)])

        XCTAssertEqual(page.rows.map(\.column), [0, 1, 0, 1, 0])
        XCTAssertEqual(
            page.rows[2].incoming,
            [seg(0, 0, color: 0), seg(1, 1, color: 1), seg(1, 0, color: 0)],
            "the merge edge lands on lane 0 in lane 0's color; no new lane is opened"
        )
        XCTAssertEqual(page.rows[4].incoming, [seg(0, 0, color: 0), seg(1, 0, color: 1)])
        XCTAssertEqual(page.state, .initial)
        Support.assertWellFormed(page.rows)
    }

    func test_GRA_02_twoBranchesFromOneCommitRunSideBySideUntilTheirParent() {
        let page = layout([commit(3, 1), commit(2, 1), commit(1)])

        XCTAssertEqual(page.rows.map(\.column), [0, 1, 0])
        XCTAssertEqual(page.rows[1].incoming, [seg(0, 0, color: 0)])
        XCTAssertEqual(page.rows[2].incoming, [seg(0, 0, color: 0), seg(1, 0, color: 1)])
        Support.assertWellFormed(page.rows)
    }

    // MARK: - GRA-03

    func test_GRA_03_octopusOpensOneLanePerExtraParent() {
        let page = layout([commit(5, 2, 3, 4), commit(2, 1), commit(3, 1), commit(4, 1), commit(1)])

        XCTAssertEqual(page.rows.map(\.column), [0, 0, 1, 2, 0])
        XCTAssertEqual(page.rows.map(\.colorIndex), [0, 0, 1, 2, 0])
        XCTAssertEqual(
            page.rows.map(\.incoming),
            [
                [],
                [seg(0, 0, color: 0), seg(0, 1, color: 1), seg(0, 2, color: 2)],
                [seg(0, 0, color: 0), seg(1, 1, color: 1), seg(2, 2, color: 2)],
                [seg(0, 0, color: 0), seg(1, 1, color: 1), seg(2, 2, color: 2)],
                [seg(0, 0, color: 0), seg(1, 0, color: 1), seg(2, 0, color: 2)],
            ]
        )
        XCTAssertEqual(page.state, .initial)
        Support.assertWellFormed(page.rows)
    }

    func test_GRA_03_octopusParentThatIsTheNextCommitConvergesStraightIntoIt() {
        let page = layout([commit(5, 2, 3, 4), commit(4, 1), commit(3, 1), commit(2, 1), commit(1)])

        XCTAssertEqual(page.rows.map(\.column), [0, 2, 1, 0, 0])
        XCTAssertEqual(page.rows[1].incoming, [seg(0, 0, color: 0), seg(0, 1, color: 1), seg(0, 2, color: 2)])
        Support.assertWellFormed(page.rows)
    }

    func test_GRA_03_laneColorIsCreationColumnModEight() {
        // A ten-parent octopus opens columns 0…9; columns 8 and 9 wrap to colors 0 and 1.
        let tips = Array(2...11)
        var commits = [commit(100, parents: tips)]
        commits += tips.reversed().map { commit($0, 1) }
        commits.append(commit(1))
        let page = layout(commits)

        let columns = page.rows.dropFirst().prefix(tips.count).map(\.column)
        let colors = page.rows.dropFirst().prefix(tips.count).map(\.colorIndex)
        XCTAssertEqual(columns, Array((0...9).reversed()))
        XCTAssertEqual(colors, [1, 0, 7, 6, 5, 4, 3, 2, 1, 0])
        XCTAssertEqual(page.rows[1].incoming.last, seg(0, 9, color: 1))
        Support.assertWellFormed(page.rows)
    }

    func test_GRA_03_duplicateAndSelfParentsAreIgnored() {
        let page = layout([commit(3, 2, 2, 3), commit(2, 1), commit(1)])

        XCTAssertEqual(page.rows.map(\.column), [0, 0, 0])
        XCTAssertEqual(page.rows[1].incoming, [seg(0, 0, color: 0)])
        XCTAssertEqual(page.state, .initial)
    }

    // MARK: - GRA-04

    func test_GRA_04_unrelatedHistoriesGetTheirOwnLanes() {
        // 4→2 and 3→1 never meet. 5 is an orphan tip that appears after both roots.
        let page = layout([commit(4, 2), commit(3, 1), commit(2), commit(1), commit(5)])

        XCTAssertEqual(page.rows.map(\.column), [0, 1, 0, 1, 0])
        XCTAssertEqual(page.rows.map(\.colorIndex), [0, 1, 0, 1, 0])
        XCTAssertEqual(
            page.rows.map(\.incoming),
            [
                [],
                [seg(0, 0, color: 0)],
                [seg(0, 0, color: 0), seg(1, 1, color: 1)],
                [seg(1, 1, color: 1)],
                [],
            ]
        )
        XCTAssertEqual(page.state, .initial)
        Support.assertWellFormed(page.rows)
    }

    func test_GRA_04_freedColumnIsReusedAndTheNewLaneTakesThatColumnsColor() {
        // Lane 0 ends at root 2 while lane 1 is still open; the next tip 6 reuses column 0.
        let page = layout([commit(3, 2), commit(5, 4), commit(2), commit(6, 4), commit(4)])

        XCTAssertEqual(page.rows.map(\.column), [0, 1, 0, 0, 0])
        XCTAssertEqual(page.rows.map(\.colorIndex), [0, 1, 0, 0, 0])
        XCTAssertEqual(page.rows[3].incoming, [seg(1, 1, color: 1)])
        XCTAssertEqual(page.rows[4].incoming, [seg(0, 0, color: 0), seg(1, 0, color: 1)])
        Support.assertWellFormed(page.rows)
    }

    // MARK: - GRA-05

    func test_GRA_05_pagesContinueFromThePreviousState() {
        let history = Support.benchHistory(commitCount: 200, shortLanes: 6)
        let whole = layout(history)

        for split in 0...history.count {
            let first = GraphEngine.layout(Array(history[..<split]))
            let second = GraphEngine.layout(Array(history[split...]), continuing: first.state)
            XCTAssertEqual(first.rows + second.rows, whole.rows, "split at \(split)")
            XCTAssertEqual(second.state, whole.state, "split at \(split)")
        }
    }

    func test_GRA_05_mergeEdgeCutByPageBoundaryIsDrawnOnTheNextPage() {
        let first = layout([commit(4, 2, 3)])

        XCTAssertEqual(
            first.state.pendingSegments,
            [seg(0, 0, color: 0), seg(0, 1, color: 1)],
            "the renderer draws these below the last loaded row"
        )

        let second = GraphEngine.layout([commit(3, 1), commit(2, 1), commit(1)], continuing: first.state)
        XCTAssertEqual(second.rows.map(\.column), [1, 0, 0])
        XCTAssertEqual(second.rows[0].incoming, [seg(0, 0, color: 0), seg(0, 1, color: 1)])
        XCTAssertEqual(second.state, .initial)
    }

    func test_GRA_05_laneColorSurvivesPageBoundary() {
        let first = layout([commit(5, 2, 3, 4)])
        let second = GraphEngine.layout([commit(2, 1), commit(3, 1), commit(4, 1)], continuing: first.state)

        XCTAssertEqual(second.rows.map(\.colorIndex), [0, 1, 2])
        XCTAssertEqual(second.state.pendingSegments, [seg(0, 0, color: 0), seg(1, 1, color: 1), seg(2, 2, color: 2)])
    }

    // MARK: - GRA-06

    func test_GRA_06_longLivedAndShortBranchesKeepStableLanes() {
        let history = Support.benchHistory(commitCount: 2_000)
        let page = layout(history)

        XCTAssertEqual(page.rows.count, history.count)
        XCTAssertEqual(page.rows.map(\.oid), history.map(\.oid))
        // Lane colors stay fixed from row to row; assertWellFormed checks every continuing line.
        Support.assertWellFormed(page.rows)

        // main + two long-lived branches + ten short branches, plus a transient lane per merge: freed columns are
        // reused, so the graph does not keep widening as short branches come and go.
        let widest =
            page.rows.map { row in
                (row.incoming.map { max($0.from, $0.to) } + [row.column]).max() ?? 0
            }
            .max() ?? 0
        XCTAssertLessThan(widest, 16)

        // Every first-parent link is drawn: the parent's row receives a line from the child's column.
        let rowIndexByOID = Dictionary(
            page.rows.indices.map { (page.rows[$0].oid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (index, commit) in history.enumerated() {
            guard let parent = commit.parents.first, let parentIndex = rowIndexByOID[parent] else { continue }
            let parentRow = page.rows[parentIndex]
            let arrivals = parentRow.incoming.filter { $0.to == parentRow.column }.map(\.from)
            let reachesParent = arrivals.contains(page.rows[index].column)
            XCTAssertTrue(reachesParent, "commit \(commit.subject) → parent row \(parentIndex)")
        }
    }

    // MARK: - GRA-07

    func test_GRA_07_missingParentKeepsItsLaneOpen() {
        // 9 is not in the list (shallow or cut history).
        let page = layout([commit(3, 9), commit(2, 1), commit(1)])

        XCTAssertEqual(page.rows.map(\.column), [0, 1, 1])
        XCTAssertEqual(page.rows[1].incoming, [seg(0, 0, color: 0)])
        XCTAssertEqual(page.rows[2].incoming, [seg(0, 0, color: 0), seg(1, 1, color: 1)])
        XCTAssertEqual(page.state.pendingSegments, [seg(0, 0, color: 0)])
        Support.assertWellFormed(page.rows)
    }

    func test_GRA_07_commitListedTwiceDoesNotCorruptLanes() {
        let page = layout([commit(3, 2), commit(2, 1), commit(2, 1), commit(1)])

        // The second 2 is a tip nobody waits for, so it opens its own lane; both lanes meet again at 1.
        XCTAssertEqual(page.rows.map(\.column), [0, 0, 1, 0])
        XCTAssertEqual(page.rows[2].incoming, [seg(0, 0, color: 0)])
        XCTAssertEqual(page.rows[3].incoming, [seg(0, 0, color: 0), seg(1, 0, color: 1)])
        XCTAssertEqual(page.state, .initial)
        Support.assertWellFormed(page.rows)
    }

    // MARK: - GRA-08

    func test_GRA_08_sameInputGivesSameLayout() {
        let history = Support.benchHistory(commitCount: 1_000)

        XCTAssertEqual(layout(history), layout(history))
        XCTAssertEqual(Support.benchHistory(commitCount: 1_000), history, "the synthetic history is deterministic")
    }
}
