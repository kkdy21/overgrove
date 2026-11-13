import Foundation
import XCTest

@testable import Overgrove

/// Graph column widths, the `⋯` hide menu, and wide-lane scrolling (art-direction.md §5.1, interaction.md §2.1, #255).
final class GraphColumnLayoutTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsAreTheIdealWidthsWithEveryColumnShown() {
        let layout = GraphColumnLayout.default
        XCTAssertEqual(layout.width(of: .refs), 172)
        XCTAssertEqual(layout.width(of: .author), 108)
        XCTAssertEqual(layout.width(of: .date), 52)
        XCTAssertEqual(layout.width(of: .sha), 72)
        XCTAssertEqual(layout.trailingColumns, [.author, .date, .sha])
    }

    func testResizingIsClampedToEachColumnsRange() {
        let layout = GraphColumnLayout.default
        XCTAssertEqual(layout.resizing(.refs, by: 40).width(of: .refs), 212)
        XCTAssertEqual(layout.resizing(.refs, by: -500).width(of: .refs), 96)
        XCTAssertEqual(layout.resizing(.refs, by: 500).width(of: .refs), 280)
        XCTAssertEqual(layout.resizing(.author, by: 500).width(of: .author), 200)
        XCTAssertEqual(layout.resizing(.date, by: -500).width(of: .date), 44)
        XCTAssertEqual(layout.resizing(.sha, by: 500).width(of: .sha), 96)
        XCTAssertEqual(layout.resizing(.sha, by: 500).limitState(of: .sha), .atMaximum)
        XCTAssertEqual(layout.resizing(.sha, by: -500).limitState(of: .sha), .atMinimum)
        XCTAssertEqual(layout.limitState(of: .sha), .between)
    }

    func testWideningStopsWhereMessageWouldGoUnderItsMinimum() {
        let layout = GraphColumnLayout.default
        // 172 + 54 + 108 + 52 + 72 = 458 fixed; a 700pt panel leaves Message 242, so 42pt of room.
        XCTAssertEqual(layout.fixedWidth(graphWidth: 54), 458)
        let widened = layout.resizing(.author, by: 80, panelWidth: 700, graphWidth: 54)
        XCTAssertEqual(widened.width(of: .author), 150)
        XCTAssertEqual(
            layout.resizing(.author, by: -30, panelWidth: 300, graphWidth: 54).width(of: .author), 78,
            "narrowing always applies, even in a cramped panel")
        XCTAssertEqual(layout.toggling(.sha).fixedWidth(graphWidth: 54), 386, "hidden columns take no room")
    }

    func testOnlyAuthorDateAndShaCanBeHidden() {
        let layout = GraphColumnLayout.default.toggling(.author).toggling(.sha).toggling(.refs)
        XCTAssertFalse(layout.isVisible(.author))
        XCTAssertTrue(layout.isVisible(.refs), "Refs cannot be hidden")
        XCTAssertEqual(layout.trailingColumns, [.date])
        XCTAssertEqual(layout.drawnWidth(of: .author), 0)
        XCTAssertEqual(layout.width(of: .author), 108, "the width is kept for when it comes back")
        XCTAssertEqual(layout.toggling(.author).trailingColumns, [.author, .date])
    }

    func testFittingUsesTheWidestContentPlusPadding() {
        XCTAssertEqual(GraphColumnLayout.fittedWidth(.author, contentWidths: [40, 81.2, 60]), 82 + 16)
        XCTAssertEqual(GraphColumnLayout.fittedWidth(.author, contentWidths: [10]), 72, "at least the minimum")
        XCTAssertEqual(GraphColumnLayout.fittedWidth(.author, contentWidths: [900]), 200, "at most the maximum")
        XCTAssertEqual(GraphColumnLayout.fittedWidth(.refs, contentWidths: [150]), 158)
        XCTAssertEqual(GraphColumnLayout.fittedWidth(.date, contentWidths: []), 52, "nothing loaded: the ideal")
    }

    func testColumnsAreSavedPerRepositoryAndSanitizedOnLoad() throws {
        let store = PanelLayoutStore(defaults: defaults)
        func key(_ id: String) -> String { store.key(for: id, prefix: PanelLayoutStore.columnsKeyPrefix) }
        XCTAssertEqual(store.columns(for: "/tmp/a/.git"), .default)
        let a = GraphColumnLayout.default.setting(.refs, to: 220).toggling(.date)
        store.save(a, for: "/tmp/a/.git")
        let reopened = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(reopened.columns(for: "/tmp/a/.git"), a)
        XCTAssertEqual(reopened.columns(for: "/tmp/b/.git"), .default)
        XCTAssertEqual(reopened.layout(for: "/tmp/a/.git"), .default, "panel layout is a separate value")

        // Written by another version: out-of-range widths, an unknown column, and Refs hidden.
        let foreign = #"{"widths":{"refs":5000,"sha":10,"lanes":30},"hidden":["refs","author","future"]}"#
        defaults.set(Data(foreign.utf8), forKey: key("/tmp/c/.git"))
        let restored = store.columns(for: "/tmp/c/.git")
        XCTAssertEqual(restored.width(of: .refs), 280)
        XCTAssertEqual(restored.width(of: .sha), 64)
        XCTAssertTrue(restored.isVisible(.refs))
        XCTAssertFalse(restored.isVisible(.author))

        defaults.set(Data("not json".utf8), forKey: key("/tmp/d/.git"))
        XCTAssertEqual(store.columns(for: "/tmp/d/.git"), .default)
    }

    func testKeysDoNotContainThePath() {
        let store = PanelLayoutStore(defaults: defaults)
        let key = store.key(for: "/tmp/secret-project/.git", prefix: PanelLayoutStore.columnsKeyPrefix)
        XCTAssertTrue(key.hasPrefix("graphColumns."))
        XCTAssertFalse(key.contains("secret-project"))
    }

    // MARK: Wide lanes

    func testUpToTwelveLanesNothingScrolls() {
        XCTAssertEqual(GraphGeometry.standard.width(lanes: 12), 12 * 20 + 14)
        XCTAssertEqual(GraphGeometry.standard.maxOffset(lanes: 12), 0)
        XCTAssertEqual(GraphGeometry.standard.clampOffset(30, lanes: 5), 0)
    }

    func testMoreThanTwelveLanesScrollInsideTheColumn() {
        XCTAssertEqual(GraphGeometry.standard.width(lanes: 20), 12 * 20 + 14, "the column stays at 12 lanes")
        XCTAssertEqual(GraphGeometry.standard.contentWidth(lanes: 20), 20 * 20 + 14)
        XCTAssertEqual(GraphGeometry.standard.maxOffset(lanes: 20), 160)
        XCTAssertEqual(GraphGeometry.standard.clampOffset(-4, lanes: 20), 0)
        XCTAssertEqual(GraphGeometry.standard.clampOffset(500, lanes: 20), 160)
        XCTAssertEqual(GraphGeometry.standard.clampOffset(.nan, lanes: 20), 0)
    }

    func testRevealingAColumnMovesAsLittleAsPossible() {
        // Visible lanes 0–11 at offset 0.
        XCTAssertEqual(GraphGeometry.standard.revealing(3, offset: 0, lanes: 20), 0, "already visible")
        // Lane 15's right edge (7 + 16 × 20 + 7 = 334) against a 254pt column.
        XCTAssertEqual(GraphGeometry.standard.revealing(15, offset: 0, lanes: 20), 80)
        // Back to lane 1 from the far right: its left edge (7 + 20 − 7 = 20).
        XCTAssertEqual(GraphGeometry.standard.revealing(1, offset: 160, lanes: 20), 20)
        XCTAssertEqual(GraphGeometry.standard.revealing(0, offset: 160, lanes: 20), 0)
        XCTAssertEqual(GraphGeometry.standard.revealing(19, offset: 0, lanes: 20), 160)
    }

    // MARK: Fitting a narrow panel (#574)

    private func messageWidth(_ layout: GraphColumnLayout, panel: CGFloat, graph: CGFloat) -> CGFloat {
        panel - layout.fixedWidth(graphWidth: graph)
    }

    func testAWidePanelDrawsTheStoredLayout() {
        let layout = GraphColumnLayout.default
        XCTAssertEqual(layout.fitting(panelWidth: 1_200, graphWidth: 80), layout)
    }

    /// The graph panel's minimum (480 pt) with the ideal widths left Message one character wide.
    func testTheMinimumWidthKeepsMessageAtItsMinimum() {
        let fitted = GraphColumnLayout.default.fitting(panelWidth: 480, graphWidth: 80)
        XCTAssertGreaterThanOrEqual(
            messageWidth(fitted, panel: 480, graph: 80), GraphColumnLayout.messageMinimum - 0.5)
        XCTAssertEqual(fitted.width(of: .refs), GraphColumnLayout.Column.refs.limits.minimum)
        XCTAssertEqual(fitted.width(of: .author), GraphColumnLayout.Column.author.limits.minimum)
    }

    /// Refs gives way before Author, and both only as far as needed; Date and SHA go only after both are at minimum.
    func testColumnsShrinkBeforeAnyIsHidden() {
        let layout = GraphColumnLayout.default
        let full = layout.fixedWidth(graphWidth: 80) + GraphColumnLayout.messageMinimum
        let slightly = layout.fitting(panelWidth: full - 10, graphWidth: 80)
        XCTAssertEqual(slightly.width(of: .refs), layout.width(of: .refs) - 10)
        XCTAssertEqual(slightly.width(of: .author), layout.width(of: .author))
        XCTAssertEqual(slightly.trailingColumns, [.author, .date, .sha])

        let shrunk =
            full - (layout.width(of: .refs) - GraphColumnLayout.Column.refs.limits.minimum)
            - (layout.width(of: .author) - GraphColumnLayout.Column.author.limits.minimum)
        XCTAssertEqual(layout.fitting(panelWidth: shrunk, graphWidth: 80).trailingColumns, [.author, .date, .sha])
        XCTAssertEqual(layout.fitting(panelWidth: shrunk - 1, graphWidth: 80).trailingColumns, [.author, .sha])
        let noDate = shrunk - layout.width(of: .date)
        XCTAssertEqual(layout.fitting(panelWidth: noDate - 1, graphWidth: 80).trailingColumns, [.author])
    }

    /// Fitting is for drawing only: the stored layout, its hidden set, and a column hidden by the user stay as they are.
    func testFittingKeepsWhatTheUserHid() {
        let layout = GraphColumnLayout.default.toggling(.date)
        let fitted = layout.fitting(panelWidth: 300, graphWidth: 80)
        XCTAssertFalse(fitted.isVisible(.date))
        XCTAssertFalse(fitted.isVisible(.sha))
        XCTAssertFalse(fitted.isVisible(.author), "Author goes last, after Date and SHA (#603)")
        XCTAssertTrue(layout.isVisible(.sha))
        XCTAssertTrue(layout.isVisible(.author))
    }

    // MARK: Many lanes in a narrow panel (#603)

    private func message(_ fitted: GraphColumnLayout, panel: CGFloat, lanes: Int) -> CGFloat {
        let visible = fitted.visibleLanes(panelWidth: panel, lanes: lanes)
        return panel - fitted.fixedWidth(graphWidth: GraphGeometry.standard.showing(lanes: visible).width(lanes: lanes))
    }

    /// Twelve lanes are 254 pt: at the panel's 480 pt minimum they left Message 58 pt once Refs and Author were at
    /// their minimums and Date and SHA hidden.
    func testTwelveLanesKeepMessageAtItsMinimum() {
        let fitted = GraphColumnLayout.default.fitting(panel: 480, lanes: 12)
        XCTAssertEqual(fitted.trailingColumns, [], "Date, SHA, then Author are hidden")
        let visible = fitted.visibleLanes(panelWidth: 480, lanes: 12)
        XCTAssertEqual(visible, 8)
        XCTAssertGreaterThanOrEqual(message(fitted, panel: 480, lanes: 12), GraphColumnLayout.messageMinimum)
    }

    /// Lanes give way only after every other column: a panel where hiding Author is enough keeps all twelve lanes.
    func testLanesShrinkOnlyAfterAuthorIsHidden() {
        let layout = GraphColumnLayout.default
        let graph = GraphGeometry.standard.width(lanes: 12)
        let withAuthor =
            GraphColumnLayout.Column.refs.limits.minimum + graph
            + GraphColumnLayout.Column.author.limits.minimum + GraphColumnLayout.messageMinimum
        let justEnough = withAuthor - GraphColumnLayout.Column.author.limits.minimum
        let fitted = layout.fitting(panel: justEnough, lanes: 12)
        XCTAssertFalse(fitted.isVisible(.author))
        XCTAssertEqual(fitted.visibleLanes(panelWidth: justEnough, lanes: 12), 12)
        XCTAssertEqual(layout.fitting(panel: withAuthor, lanes: 12).trailingColumns, [.author])
    }

    func testVisibleLanesStayWithinTheirRange() {
        let fitted = GraphColumnLayout.default.fitting(panel: 300, lanes: 20)
        XCTAssertEqual(fitted.visibleLanes(panelWidth: 300, lanes: 20), GraphColumnLayout.minimumVisibleLanes)
        XCTAssertEqual(GraphColumnLayout.default.visibleLanes(panelWidth: 2_000, lanes: 20), 12, "never more than 12")
        XCTAssertEqual(
            GraphColumnLayout.default.visibleLanes(panelWidth: 2_000, lanes: 2), 2, "never more than there are")
    }

    /// The geometry's lane cap: the column narrows and the rest scroll inside it.
    func testGeometryShowingFewerLanesScrollsTheRest() {
        let geometry = GraphGeometry.standard.showing(lanes: 8)
        XCTAssertEqual(geometry.width(lanes: 12), 8 * geometry.lane + geometry.inset * 2)
        XCTAssertEqual(geometry.maxOffset(lanes: 12), 4 * geometry.lane)
        XCTAssertEqual(geometry.width(lanes: 5), 5 * geometry.lane + geometry.inset * 2)
    }

    /// A divider drag starts from the widths on screen. From the stored widths, the first points of a drag would only
    /// eat into what `fitting` had already taken, and the divider would not move under the pointer.
    func testDragStartsFromTheWidthsOnScreen() {
        let stored = GraphColumnLayout.default
        let full = stored.fixedWidth(graphWidth: 80) + GraphColumnLayout.messageMinimum
        let shown = stored.fitting(panelWidth: full - 10, graphWidth: 80)
        XCTAssertEqual(shown.width(of: .refs), stored.width(of: .refs) - 10)

        let base = stored.adoptingWidths(from: shown)
        let dragged = base.resizing(.refs, by: -5, panelWidth: full - 10, graphWidth: 80)
        XCTAssertEqual(
            dragged.fitting(panelWidth: full - 10, graphWidth: 80).width(of: .refs), shown.width(of: .refs) - 5)

        let fromStored = stored.resizing(.refs, by: -5, panelWidth: full - 10, graphWidth: 80)
        XCTAssertEqual(
            fromStored.fitting(panelWidth: full - 10, graphWidth: 80).width(of: .refs), shown.width(of: .refs),
            "the old base: the divider stayed put")
    }

    /// The drag base keeps the stored visibility: a column that `fitting` hid is not saved as hidden.
    func testDragBaseKeepsTheStoredVisibility() {
        let stored = GraphColumnLayout.default
        let shown = stored.fitting(panel: 480, lanes: 12)
        XCTAssertFalse(shown.isVisible(.date))
        let base = stored.adoptingWidths(from: shown)
        XCTAssertTrue(base.isVisible(.date))
        XCTAssertTrue(base.isVisible(.author))
        XCTAssertEqual(base.width(of: .refs), shown.width(of: .refs))
    }
}
