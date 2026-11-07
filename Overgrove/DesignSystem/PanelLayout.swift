import CoreGraphics
import Foundation

/// Widths of the three main-window panels (#174, ADR-0014, interaction.md §2.1, art-direction.md §3.2).
///
/// A pure value type so all sizing rules are unit-testable without UI. It stores the user's *preferred* sidebar and
/// detail widths and collapse state; `resolved(windowWidth:)` turns them into the widths actually drawn. Shrinking
/// the window never rewrites the preferences, so widening it gives the old widths back.
///
/// Layout from leading to trailing: gutter, sidebar, gutter (sidebar divider), center, gutter (detail divider),
/// detail, gutter. A collapsed panel takes its divider gutter with it. The center never collapses.
struct PanelLayout: Codable, Equatable, Sendable {
    /// A collapsible panel, named after the divider next to it.
    enum Side: String, Codable, CaseIterable, Sendable {
        case sidebar
        case detail

        /// VoiceOver label of the divider; the width is the value (`Sidebar width, 256 points`).
        var accessibilityLabel: String {
            switch self {
            case .sidebar: "Sidebar width"
            case .detail: "Detail width"
            }
        }
    }

    struct Limits: Equatable, Sendable {
        let minimum: CGFloat
        let ideal: CGFloat
        let maximum: CGFloat
    }

    enum Edge: Sendable {
        case minimum
        case maximum
    }

    /// Where a divider is within its range; the cursor shows only the direction that still moves (art-direction §3.2).
    enum LimitState: Equatable, Sendable {
        case atMinimum
        case between
        case atMaximum
    }

    /// Widths as drawn. `nil` means collapsed.
    struct Resolved: Equatable, Sendable {
        let sidebar: CGFloat?
        let center: CGFloat
        let detail: CGFloat?

        func width(of side: Side) -> CGFloat? {
            side == .sidebar ? sidebar : detail
        }
    }

    /// The result of a drag in progress.
    struct Drag: Equatable, Sendable {
        /// What to draw while dragging. A pending collapse keeps the panel visible at its minimum.
        let layout: PanelLayout
        /// Released now, the panel would collapse; the view shows it translucent as a preview.
        let isCollapsePending: Bool
    }

    // MARK: Rules (tokens.json `size.*`; numbers without a token cite interaction.md §2.1)

    static func limits(for side: Side) -> Limits {
        switch side {
        case .sidebar:
            Limits(
                minimum: Tokens.Size.sidebarWidthMin, ideal: Tokens.Size.sidebarWidthIdeal,
                maximum: Tokens.Size.sidebarWidthMax)
        case .detail:
            Limits(
                minimum: Tokens.Size.detailWidthMin, ideal: Tokens.Size.detailWidthIdeal,
                maximum: Tokens.Size.detailWidthMax)
        }
    }

    static let centerMinimum = Tokens.Size.graphWidthMin
    static let gap = Tokens.Size.panelGap
    /// Dragging a panel this far past its minimum collapses it on release (interaction.md §2.1).
    static let collapseOvershoot: CGFloat = 40
    /// `←` / `→` on a focused divider (interaction.md §2.1: 8pt).
    static let keyboardStep = Tokens.Spacing.sm

    static let `default` = PanelLayout(
        sidebarWidth: limits(for: .sidebar).ideal, detailWidth: limits(for: .detail).ideal)

    // MARK: State

    var sidebarWidth: CGFloat
    var detailWidth: CGFloat
    var isSidebarCollapsed = false
    var isDetailCollapsed = false

    init(sidebarWidth: CGFloat, detailWidth: CGFloat, isSidebarCollapsed: Bool = false, isDetailCollapsed: Bool = false)
    {
        self.sidebarWidth = sidebarWidth
        self.detailWidth = detailWidth
        self.isSidebarCollapsed = isSidebarCollapsed
        self.isDetailCollapsed = isDetailCollapsed
    }

    func width(of side: Side) -> CGFloat {
        side == .sidebar ? sidebarWidth : detailWidth
    }

    func isCollapsed(_ side: Side) -> Bool {
        side == .sidebar ? isSidebarCollapsed : isDetailCollapsed
    }

    // MARK: Resolving

    /// The smallest window that still fits every visible panel at its minimum and the center at its minimum.
    /// Collapsing a panel lowers it by that panel's minimum and its gutter (tokens.json `size.window-min-width`).
    var minimumWindowWidth: CGFloat {
        var width = Tokens.Size.windowMinWidth
        for side in Side.allCases where isCollapsed(side) {
            width -= Self.limits(for: side).minimum + Self.gap
        }
        return width
    }

    /// Room for panels: the window minus one gutter per visible panel plus the outer one.
    private func panelSpace(windowWidth: CGFloat) -> CGFloat {
        let visible = 1 + Side.allCases.filter { !isCollapsed($0) }.count
        return windowWidth - CGFloat(visible + 1) * Self.gap
    }

    private func clamped(_ side: Side) -> CGFloat {
        let limits = Self.limits(for: side)
        return min(max(width(of: side), limits.minimum), limits.maximum)
    }

    /// Widths to draw. The center takes the rest; when it would drop below its minimum, the detail shrinks first and
    /// then the sidebar, each down to its own minimum (interaction.md §2.1).
    func resolved(windowWidth: CGFloat) -> Resolved {
        let space = panelSpace(windowWidth: windowWidth)
        var sidebar = isSidebarCollapsed ? 0 : clamped(.sidebar)
        var detail = isDetailCollapsed ? 0 : clamped(.detail)
        var deficit = Self.centerMinimum - (space - sidebar - detail)
        if deficit > 0, !isDetailCollapsed {
            let give = min(deficit, detail - Self.limits(for: .detail).minimum)
            detail -= give
            deficit -= give
        }
        if deficit > 0, !isSidebarCollapsed {
            sidebar -= min(deficit, sidebar - Self.limits(for: .sidebar).minimum)
        }
        return Resolved(
            sidebar: isSidebarCollapsed ? nil : sidebar,
            center: max(space - sidebar - detail, 0),
            detail: isDetailCollapsed ? nil : detail
        )
    }

    /// The widest `side` can be in this window: its own maximum, or less if the center would drop below its minimum.
    func maximumWidth(of side: Side, windowWidth: CGFloat) -> CGFloat {
        let limits = Self.limits(for: side)
        let other: Side = side == .sidebar ? .detail : .sidebar
        let otherWidth = resolved(windowWidth: windowWidth).width(of: other) ?? 0
        let room = panelSpace(windowWidth: windowWidth) - otherWidth - Self.centerMinimum
        return max(limits.minimum, min(limits.maximum, room))
    }

    func limitState(_ side: Side, windowWidth: CGFloat) -> LimitState {
        guard let width = resolved(windowWidth: windowWidth).width(of: side) else { return .between }
        if width <= Self.limits(for: side).minimum { return .atMinimum }
        if width >= maximumWidth(of: side, windowWidth: windowWidth) { return .atMaximum }
        return .between
    }

    func accessibilityValue(_ side: Side, windowWidth: CGFloat) -> String {
        let width = resolved(windowWidth: windowWidth).width(of: side) ?? 0
        return "\(Int(width.rounded())) points"
    }

    // MARK: Changes

    private func setting(_ side: Side, width: CGFloat) -> PanelLayout {
        var copy = self
        if side == .sidebar { copy.sidebarWidth = width } else { copy.detailWidth = width }
        return copy
    }

    private func setting(_ side: Side, collapsed: Bool) -> PanelLayout {
        var copy = self
        if side == .sidebar { copy.isSidebarCollapsed = collapsed } else { copy.isDetailCollapsed = collapsed }
        return copy
    }

    /// Pointer translation is in window coordinates (positive = right). The sidebar grows with it; the detail, whose
    /// divider is on its leading edge, grows against it.
    private static func proposedWidth(_ side: Side, from startWidth: CGFloat, by translation: CGFloat) -> CGFloat {
        side == .sidebar ? startWidth + translation : startWidth - translation
    }

    /// The layout while dragging `side`'s divider, starting from the width drawn when the drag began.
    func drag(_ side: Side, from startWidth: CGFloat, by translation: CGFloat, windowWidth: CGFloat) -> Drag {
        let limits = Self.limits(for: side)
        let proposed = Self.proposedWidth(side, from: startWidth, by: translation)
        if proposed < limits.minimum - Self.collapseOvershoot {
            return Drag(layout: setting(side, width: limits.minimum), isCollapsePending: true)
        }
        let width = min(max(proposed, limits.minimum), maximumWidth(of: side, windowWidth: windowWidth))
        return Drag(layout: setting(side, width: width), isCollapsePending: false)
    }

    /// The layout once the drag is released: either the dragged width, or collapsed with the pre-drag width kept
    /// so reopening restores it.
    func endDrag(_ side: Side, from startWidth: CGFloat, by translation: CGFloat, windowWidth: CGFloat) -> PanelLayout {
        let drag = drag(side, from: startWidth, by: translation, windowWidth: windowWidth)
        guard drag.isCollapsePending else { return drag.layout }
        return setting(side, width: startWidth).setting(side, collapsed: true)
    }

    /// Double-click on a divider: that panel back to its ideal width.
    func reset(_ side: Side) -> PanelLayout {
        setting(side, width: Self.limits(for: side).ideal).setting(side, collapsed: false)
    }

    /// `←` / `→`: `steps` keyboard steps, where positive widens the panel. Never collapses.
    func step(_ side: Side, by steps: Int, windowWidth: CGFloat) -> PanelLayout {
        let current = resolved(windowWidth: windowWidth).width(of: side) ?? width(of: side)
        let proposed = current + CGFloat(steps) * Self.keyboardStep
        let width = min(
            max(proposed, Self.limits(for: side).minimum), maximumWidth(of: side, windowWidth: windowWidth))
        return setting(side, width: width)
    }

    /// `⌥←` / `⌥→`: straight to the minimum or the maximum that fits.
    func moveToEdge(_ side: Side, _ edge: Edge, windowWidth: CGFloat) -> PanelLayout {
        switch edge {
        case .minimum: setting(side, width: Self.limits(for: side).minimum)
        case .maximum: setting(side, width: maximumWidth(of: side, windowWidth: windowWidth))
        }
    }

    /// `⌃⌘S` / `⌥⌘0` / View menu: collapse or reopen. The stored width is kept.
    func toggling(_ side: Side) -> PanelLayout {
        setting(side, collapsed: !isCollapsed(side))
    }

    /// Values read back from storage, clamped to the current rules (tokens can change between versions).
    func sanitized() -> PanelLayout {
        func valid(_ value: CGFloat, _ side: Side) -> CGFloat {
            let limits = Self.limits(for: side)
            guard value.isFinite else { return limits.ideal }
            return min(max(value, limits.minimum), limits.maximum)
        }
        return PanelLayout(
            sidebarWidth: valid(sidebarWidth, .sidebar), detailWidth: valid(detailWidth, .detail),
            isSidebarCollapsed: isSidebarCollapsed, isDetailCollapsed: isDetailCollapsed)
    }
}
