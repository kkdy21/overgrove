import Foundation
import XCTest

@testable import Overgrove

/// `WipDetailModel` line counts (#230, screens.md S-02): per-file `+n −m`, group and summary totals, binary files.
final class WipDetailLineCountTests: XCTestCase {
    private func change(_ path: String, _ status: FileChange.Status, submodule: Bool = false) -> FileChange {
        FileChange(path: GitPath(path), status: status, isSubmodule: submodule)
    }

    private func state(
        staged: [FileChange] = [], unstaged: [FileChange] = [], untracked: [FileChange] = [],
        conflicted: [FileChange] = []
    ) -> WorkingState {
        WorkingState(
            headCommit: ObjectID("a91f3c2000000000000000000000000000000000"), head: .branch("main"),
            upstream: .none, stashCount: 0, staged: staged, unstaged: unstaged, untracked: untracked,
            conflicted: conflicted, isPartial: false, skippedRecords: 0)
    }

    private func stat(_ path: String, _ added: Int?, _ deleted: Int?) -> FileStat {
        FileStat(path: GitPath(path), added: added, deleted: deleted)
    }

    private func model(_ state: WorkingState, _ counts: WipDetailModel.LineCounts) -> WipDetailModel {
        WipDetailModel(
            entry: WorktreeListing.entry("/tmp/dev/api", branch: "main", isMain: true, state: .loaded(state)),
            lineCounts: counts, home: "/tmp/dev")
    }

    /// The S-02 mockup's numbers: Staged `+54 −12`, Unstaged `+11 −3`, summary `+65 −15`; the `MM` file counts in
    /// both groups; untracked and conflicted rows have no counts and no group total.
    private var mockup: (WorkingState, WorkingLineCounts) {
        let state = state(
            staged: [
                change("Status.swift", .modified), change("GitClient.swift", .added), change("New.swift", .modified),
            ],
            unstaged: [change("Status.swift", .modified), change("Legacy.swift", .deleted)],
            untracked: [change("notes.md", .untracked)],
            conflicted: [change("Layout.swift", .conflicted(.bothModified))])
        let counts = WorkingLineCounts(
            staged: [stat("Status.swift", 40, 8), stat("GitClient.swift", 12, 0), stat("New.swift", 2, 4)],
            unstaged: [stat("Status.swift", 9, 1), stat("Legacy.swift", 2, 2)],
            isPartial: false)
        return (state, counts)
    }

    func testRowsGroupsAndSummaryTotals() throws {
        let (state, counts) = mockup
        let model = model(state, .loaded(counts))
        let groups = Dictionary(uniqueKeysWithValues: model.groups.map { ($0.group, $0) })

        let staged = try XCTUnwrap(groups[.staged])
        XCTAssertEqual(
            staged.rows.map(\.lineCount),
            [.lines(added: 40, deleted: 8), .lines(added: 12, deleted: 0), .lines(added: 2, deleted: 4)])
        XCTAssertEqual(staged.lineTotals, WipLineTotals(added: 54, deleted: 12))
        XCTAssertEqual(groups[.unstaged]?.lineTotals, WipLineTotals(added: 11, deleted: 3))
        XCTAssertEqual(groups[.unstaged]?.rows.first?.lineCount, .lines(added: 9, deleted: 1), "MM: unstaged side")

        XCTAssertNil(groups[.untracked]?.lineTotals)
        XCTAssertEqual(groups[.untracked]?.rows.map(\.lineCount), [nil])
        XCTAssertNil(groups[.conflicted]?.lineTotals)
        XCTAssertEqual(groups[.conflicted]?.rows.map(\.lineCount), [nil])

        XCTAssertEqual(model.lineTotals, WipLineTotals(added: 65, deleted: 15))
        XCTAssertNil(model.lineCountNote)
    }

    func testZeroSideIsHidden() {
        XCTAssertEqual(WipDetailModel.lineCountText(added: 40, deleted: 8).added, "+40")
        XCTAssertEqual(WipDetailModel.lineCountText(added: 40, deleted: 8).deleted, "\u{2212}8")
        XCTAssertNil(WipDetailModel.lineCountText(added: 12, deleted: 0).deleted)
        XCTAssertNil(WipDetailModel.lineCountText(added: 0, deleted: 2).added)
        let none = WipDetailModel.lineCountText(added: 0, deleted: 0)
        XCTAssertNil(none.added)
        XCTAssertNil(none.deleted)
        XCTAssertEqual(WipDetailModel.lineCountText(added: 12_345, deleted: 0).added, "+12,345")
    }

    func testBinaryFileIsMarkedAndLeftOutOfTotals() throws {
        let state = state(staged: [change("logo.png", .added), change("a.txt", .modified)])
        let counts = WorkingLineCounts(
            staged: [stat("logo.png", nil, nil), stat("a.txt", 3, 1)], unstaged: [], isPartial: false)
        let model = model(state, .loaded(counts))
        let rows = try XCTUnwrap(model.groups.first?.rows)
        XCTAssertEqual(rows.map(\.lineCount), [.binary, .lines(added: 3, deleted: 1)])
        XCTAssertTrue(rows[0].accessibilityLabel.hasSuffix(", binary file"))
        XCTAssertTrue(rows[1].accessibilityLabel.hasSuffix(", 3 lines added, 1 removed"))
        XCTAssertEqual(model.lineTotals, WipLineTotals(added: 3, deleted: 1))
    }

    /// A submodule's numstat counts `Subproject commit` lines, so its row shows none and the total ignores it.
    func testSubmoduleRowHasNoCount() throws {
        let state = state(unstaged: [change("vendor/lib", .modified, submodule: true), change("a.txt", .modified)])
        let counts = WorkingLineCounts(
            staged: [], unstaged: [stat("vendor/lib", 1, 1), stat("a.txt", 2, 0)], isPartial: false)
        let model = model(state, .loaded(counts))
        XCTAssertEqual(model.groups.first?.rows.map(\.lineCount), [nil, .lines(added: 2, deleted: 0)])
        XCTAssertEqual(model.lineTotals, WipLineTotals(added: 2, deleted: 0))
    }

    func testPendingShowsNoCountsAndNoNote() {
        let (state, _) = mockup
        let model = model(state, .pending)
        XCTAssertTrue(model.groups.flatMap(\.rows).allSatisfy { $0.lineCount == nil })
        XCTAssertTrue(model.groups.allSatisfy { $0.lineTotals == nil })
        XCTAssertNil(model.lineTotals)
        XCTAssertNil(model.lineCountNote)
    }

    func testFailedQueryShowsANote() {
        let (state, _) = mockup
        let model = model(state, .failed)
        XCTAssertNil(model.lineTotals)
        XCTAssertEqual(model.lineCountNote, "Line counts unavailable")
    }

    /// A cut output leaves later files without counts; totals would read as complete, so none are shown.
    func testPartialCountsShowRowsButNoTotals() throws {
        let state = state(staged: [change("a.txt", .modified), change("b.txt", .modified)])
        let counts = WorkingLineCounts(staged: [stat("a.txt", 1, 0)], unstaged: [], isPartial: true)
        let model = model(state, .loaded(counts))
        XCTAssertEqual(model.groups.first?.rows.map(\.lineCount), [.lines(added: 1, deleted: 0), nil])
        XCTAssertNil(model.groups.first?.lineTotals)
        XCTAssertNil(model.lineTotals)
    }

    /// Status and numstat run at different times: a listed file missing from the numstat gets no count, and its
    /// group gets no total.
    func testFileMissingFromNumstatLeavesTheGroupWithoutTotal() {
        let state = state(staged: [change("a.txt", .modified)], unstaged: [change("b.txt", .modified)])
        let counts = WorkingLineCounts(staged: [stat("a.txt", 1, 1)], unstaged: [], isPartial: false)
        let model = model(state, .loaded(counts))
        XCTAssertEqual(model.groups.map(\.lineTotals), [WipLineTotals(added: 1, deleted: 1), nil])
        XCTAssertNil(model.lineTotals, "the summary needs every counted group")
    }

    func testRatio() {
        XCTAssertEqual(WipLineTotals(added: 65, deleted: 15).addedFraction ?? 0, 65.0 / 80.0, accuracy: 1e-9)
        XCTAssertNil(WipLineTotals(added: 0, deleted: 0).addedFraction)
        XCTAssertEqual(WipLineTotals(added: 0, deleted: 4).addedFraction, 0)
    }
}

/// Counts come from repository output, so sums that do not fit in `Int` give no total instead of trapping.
final class WipLineTotalsOverflowTests: XCTestCase {
    func testOverflowingSumGivesNoTotal() {
        let one = WipLineTotals(added: 1, deleted: 1)
        XCTAssertNil(WipLineTotals.sum([WipLineTotals(added: Int.max, deleted: 0), one]))
        XCTAssertNil(WipLineTotals.sum([WipLineTotals(added: 0, deleted: Int.max), one]))
        XCTAssertEqual(WipLineTotals.sum([]), WipLineTotals(added: 0, deleted: 0))
        XCTAssertEqual(WipLineTotals(added: Int.max, deleted: Int.max).addedFraction ?? 0, 0.5, accuracy: 1e-9)
    }
}
