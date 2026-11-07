import XCTest

@testable import Overgrove

/// #307: rows built for a document that is no longer shown are dropped, so a slow large diff finishing after a quick
/// switch cannot replace the new file's rows.
final class DiffRowsStateTests: XCTestCase {
    private func row(_ text: String) -> DiffDocument.Row {
        .hunkHeader(text)
    }

    func testLateRowsOfAnEarlierDocumentAreDropped() {
        let slow = UUID()
        let fast = UUID()
        var state = DiffRowsState()
        state.begin(slow)
        state.begin(fast)
        XCTAssertTrue(state.accept(unified: [row("fast")], for: fast))
        // The large file's build finishes last.
        XCTAssertFalse(state.accept(unified: [row("slow")], for: slow))
        XCTAssertEqual(state.unified(for: fast), [row("fast")])
        XCTAssertNil(state.unified(for: slow))
    }

    func testBeginningAnotherDocumentClearsRows() {
        let first = UUID()
        var state = DiffRowsState()
        state.begin(first)
        XCTAssertTrue(state.accept(unified: [row("a")], for: first))
        XCTAssertTrue(state.accept(split: [], for: first))
        state.begin(first)
        XCTAssertNotNil(state.unified(for: first), "the same document keeps its rows (switching split/unified)")
        state.begin(UUID())
        XCTAssertNil(state.unified(for: first))
        XCTAssertNil(state.split(for: first))
    }
}
