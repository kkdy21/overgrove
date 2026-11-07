import Foundation
import XCTest

@testable import Overgrove

/// `PanelLayout` (#174, interaction.md §2.1, art-direction.md §3.2): widths, drag, collapse, shrink order.
final class PanelLayoutTests: XCTestCase {
    private let gap = Tokens.Size.panelGap
    private let sidebar = PanelLayout.limits(for: .sidebar)
    private let detail = PanelLayout.limits(for: .detail)
    /// The reference window from art-direction.md §3.
    private let wide: CGFloat = 1440

    func testLimitsComeFromTokens() {
        XCTAssertEqual(sidebar, .init(minimum: 220, ideal: 256, maximum: 420))
        XCTAssertEqual(detail, .init(minimum: 300, ideal: 344, maximum: 560))
        XCTAssertEqual(PanelLayout.centerMinimum, 480)
        XCTAssertEqual(PanelLayout.collapseOvershoot, 40)
        XCTAssertEqual(PanelLayout.keyboardStep, 8)
    }

    // MARK: Resolving widths

    func testDefaultLayoutAtTheReferenceWindow() {
        let resolved = PanelLayout.default.resolved(windowWidth: wide)
        XCTAssertEqual(resolved.sidebar, 256)
        XCTAssertEqual(resolved.detail, 344)
        // 1440 − 4 gaps − 256 − 344: the center takes the rest.
        XCTAssertEqual(resolved.center, 1440 - 4 * gap - 256 - 344)
    }

    func testCollapsedPanelsAndTheirGutterGiveTheirSpaceToTheCenter() {
        var layout = PanelLayout.default
        layout.isSidebarCollapsed = true
        let resolved = layout.resolved(windowWidth: wide)
        XCTAssertNil(resolved.sidebar)
        XCTAssertEqual(resolved.center, 1440 - 3 * gap - 344)

        layout.isDetailCollapsed = true
        XCTAssertEqual(layout.resolved(windowWidth: wide).center, 1440 - 2 * gap)
    }

    func testStoredWidthsOutsideTheLimitsAreClamped() {
        let layout = PanelLayout(sidebarWidth: 10, detailWidth: 9_999)
        let resolved = layout.resolved(windowWidth: 2_000)
        XCTAssertEqual(resolved.sidebar, 220)
        XCTAssertEqual(resolved.detail, 560)
    }

    /// Window shrinking: the center gives up space first, then the detail, then the sidebar, each down to its
    /// minimum. The preferred widths are not changed, so widening the window restores them.
    func testShrinkOrderIsCenterThenDetailThenSidebar() {
        let layout = PanelLayout(sidebarWidth: 400, detailWidth: 500)
        // Enough for everything: center above its minimum.
        let roomy = layout.resolved(windowWidth: 4 * gap + 400 + 500 + 600)
        XCTAssertEqual(roomy, .init(sidebar: 400, center: 600, detail: 500))

        // 100pt less than needed for preferred widths with a minimum center: the detail shrinks first.
        let tighter = layout.resolved(windowWidth: 4 * gap + 400 + 500 + 480 - 100)
        XCTAssertEqual(tighter, .init(sidebar: 400, center: 480, detail: 400))

        // The detail is at its minimum (300) and 50pt is still missing: the sidebar shrinks.
        let tightest = layout.resolved(windowWidth: 4 * gap + 400 + 300 + 480 - 50)
        XCTAssertEqual(tightest, .init(sidebar: 350, center: 480, detail: 300))

        // Widening again gives the stored widths back.
        XCTAssertEqual(layout.resolved(windowWidth: 4 * gap + 400 + 500 + 600), roomy)
    }

    func testMinimumWindowWidthDropsWithCollapsedPanels() {
        var layout = PanelLayout.default
        XCTAssertEqual(layout.minimumWindowWidth, Tokens.Size.windowMinWidth)
        layout.isSidebarCollapsed = true
        XCTAssertEqual(layout.minimumWindowWidth, Tokens.Size.windowMinWidth - 220 - gap)
        layout.isDetailCollapsed = true
        XCTAssertEqual(layout.minimumWindowWidth, Tokens.Size.windowMinWidth - 220 - 300 - 2 * gap)
        // At the minimum window width, every visible panel fits at its minimum and the center keeps 480.
        for collapsed in [(false, false), (true, false), (false, true), (true, true)] {
            var probe = PanelLayout(sidebarWidth: 420, detailWidth: 560)
            probe.isSidebarCollapsed = collapsed.0
            probe.isDetailCollapsed = collapsed.1
            let resolved = probe.resolved(windowWidth: probe.minimumWindowWidth)
            XCTAssertGreaterThanOrEqual(resolved.center, PanelLayout.centerMinimum, "\(collapsed)")
        }
    }

    // MARK: Dragging

    func testDragDeltaMovesTheSidebarWithThePointer() {
        let drag = PanelLayout.default.drag(.sidebar, from: 256, by: 30, windowWidth: wide)
        XCTAssertEqual(drag.layout.sidebarWidth, 286)
        XCTAssertFalse(drag.isCollapsePending)
    }

    func testDragDeltaMovesTheDetailOppositeToThePointer() {
        // The detail divider is on the detail's leading edge: moving it left widens the detail.
        let drag = PanelLayout.default.drag(.detail, from: 344, by: -40, windowWidth: wide)
        XCTAssertEqual(drag.layout.detailWidth, 384)
    }

    func testDragStopsAtTheMaximumAndAtTheCenterMinimum() {
        let pastMax = PanelLayout.default.drag(.sidebar, from: 256, by: 1_000, windowWidth: 3_000)
        XCTAssertEqual(pastMax.layout.sidebarWidth, 420)

        // In a 1200pt window the center keeps 480: the sidebar can grow only to 1200 − 4·8 − 344 − 480 = 344.
        let squeezed = PanelLayout.default.drag(.sidebar, from: 256, by: 1_000, windowWidth: 1_200)
        XCTAssertEqual(squeezed.layout.sidebarWidth, 1_200 - 4 * gap - 344 - 480)
    }

    func testDragJustPastTheMinimumStopsAtTheMinimumWithoutCollapsing() {
        // 39pt beyond the minimum: clamps, no collapse.
        let drag = PanelLayout.default.drag(.sidebar, from: 256, by: -(256 - 220 + 39), windowWidth: wide)
        XCTAssertEqual(drag.layout.sidebarWidth, 220)
        XCTAssertFalse(drag.isCollapsePending)
        XCTAssertFalse(drag.layout.isSidebarCollapsed, "collapse happens only when the drag ends")
    }

    func testDragMoreThan40PastTheMinimumPreviewsACollapse() {
        let drag = PanelLayout.default.drag(.sidebar, from: 256, by: -(256 - 220 + 41), windowWidth: wide)
        XCTAssertTrue(drag.isCollapsePending)
        XCTAssertFalse(drag.layout.isSidebarCollapsed, "the panel stays visible as a preview until release")
        XCTAssertEqual(drag.layout.sidebarWidth, 220, "the preview shows the panel at its minimum")

        let ended = PanelLayout.default.endDrag(.sidebar, from: 256, by: -(256 - 220 + 41), windowWidth: wide)
        XCTAssertTrue(ended.isSidebarCollapsed)
        XCTAssertEqual(ended.sidebarWidth, 256, "reopening restores the width from before the drag")
    }

    func testDetailCollapsesWhenDraggedRightPastTheThreshold() {
        let ended = PanelLayout.default.endDrag(.detail, from: 344, by: 344 - 300 + 41, windowWidth: wide)
        XCTAssertTrue(ended.isDetailCollapsed)
        XCTAssertEqual(ended.detailWidth, 344)
        let kept = PanelLayout.default.endDrag(.detail, from: 344, by: 344 - 300 + 40, windowWidth: wide)
        XCTAssertFalse(kept.isDetailCollapsed)
        XCTAssertEqual(kept.detailWidth, 300)
    }

    // MARK: Double-click, keyboard, toggles

    func testDoubleClickResetsThatSideToItsIdealWidth() {
        var layout = PanelLayout(sidebarWidth: 400, detailWidth: 500)
        layout = layout.reset(.sidebar)
        XCTAssertEqual(layout.sidebarWidth, 256)
        XCTAssertEqual(layout.detailWidth, 500, "only the panels next to that divider")
        layout = layout.reset(.detail)
        XCTAssertEqual(layout.detailWidth, 344)
    }

    func testKeyboardStepsBy8AndJumpsToTheEdges() {
        let layout = PanelLayout.default
        XCTAssertEqual(layout.step(.sidebar, by: 1, windowWidth: wide).sidebarWidth, 264)
        XCTAssertEqual(layout.step(.sidebar, by: -1, windowWidth: wide).sidebarWidth, 248)
        XCTAssertEqual(layout.step(.detail, by: 1, windowWidth: wide).detailWidth, 352, "+1 widens; the view maps ←")
        XCTAssertEqual(layout.moveToEdge(.sidebar, .minimum, windowWidth: wide).sidebarWidth, 220)
        XCTAssertEqual(layout.moveToEdge(.sidebar, .maximum, windowWidth: wide).sidebarWidth, 420)
        XCTAssertEqual(
            layout.moveToEdge(.detail, .maximum, windowWidth: 1_200).detailWidth, 1_200 - 4 * gap - 256 - 480)
        // Stepping never collapses and never crosses a limit.
        XCTAssertEqual(
            layout.moveToEdge(.sidebar, .minimum, windowWidth: wide).step(.sidebar, by: -1, windowWidth: wide)
                .sidebarWidth, 220)
    }

    func testTogglesCollapseAndRestoreTheStoredWidth() {
        var layout = PanelLayout(sidebarWidth: 300, detailWidth: 344)
        layout = layout.toggling(.sidebar)
        XCTAssertTrue(layout.isSidebarCollapsed)
        layout = layout.toggling(.sidebar)
        XCTAssertFalse(layout.isSidebarCollapsed)
        XCTAssertEqual(layout.sidebarWidth, 300)
        XCTAssertTrue(layout.toggling(.detail).isDetailCollapsed)
    }

    func testLimitStateDrivesTheOneWayCursor() {
        let layout = PanelLayout.default
        XCTAssertEqual(layout.limitState(.sidebar, windowWidth: wide), .between)
        XCTAssertEqual(
            layout.moveToEdge(.sidebar, .minimum, windowWidth: wide).limitState(.sidebar, windowWidth: wide), .atMinimum
        )
        XCTAssertEqual(
            layout.moveToEdge(.sidebar, .maximum, windowWidth: wide).limitState(.sidebar, windowWidth: wide), .atMaximum
        )
        // The maximum can come from the center's minimum, not only from the panel's own limit.
        XCTAssertEqual(
            layout.moveToEdge(.detail, .maximum, windowWidth: 1_200).limitState(.detail, windowWidth: 1_200), .atMaximum
        )
    }

    func testAccessibilityValueNamesThePanelAndWidth() {
        XCTAssertEqual(PanelLayout.Side.sidebar.accessibilityLabel, "Sidebar width")
        XCTAssertEqual(PanelLayout.Side.detail.accessibilityLabel, "Detail width")
        XCTAssertEqual(PanelLayout.default.accessibilityValue(.sidebar, windowWidth: wide), "256 points")
    }
}
