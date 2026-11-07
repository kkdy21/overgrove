import AppKit
import SwiftUI

/// The main window's three-panel container (#174, ADR-0014, art-direction.md §3, interaction.md §2.1).
///
/// Sidebar, center, and detail are rounded panels on the window background, separated by 8pt gutters that act as
/// splitters. `PanelLayout` does all the width math; this view only draws it and turns pointer, keyboard, and
/// VoiceOver input into layout changes.
///
/// - `layout` is the live value (it changes on every drag frame).
/// - `onCommit` runs once per finished change (drag released, double-click, keyboard step, collapse toggle). Save
///   the layout there (`PanelLayoutStore`), not on every frame.
///
/// Drag frames only change panel frames. The panel contents are stored views, so their bodies are not re-evaluated
/// while dragging (PB-4; covered by `PanelSplitViewTests`).
struct PanelSplitView<Sidebar: View, Center: View, Detail: View>: View {
    @Binding var layout: PanelLayout
    var onCommit: (PanelLayout) -> Void
    private let sidebar: Sidebar
    private let center: Center
    private let detail: Detail

    @State private var drag: DragSession?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        layout: Binding<PanelLayout>,
        onCommit: @escaping (PanelLayout) -> Void = { _ in },
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder center: () -> Center,
        @ViewBuilder detail: () -> Detail
    ) {
        _layout = layout
        self.onCommit = onCommit
        self.sidebar = sidebar()
        self.center = center()
        self.detail = detail()
    }

    /// A drag in progress: the side, the width drawn when it began, and the pointer translation so far.
    private struct DragSession: Equatable {
        let side: PanelLayout.Side
        let startWidth: CGFloat
        var translation: CGFloat
    }

    private static var gap: CGFloat { PanelLayout.gap }

    var body: some View {
        GeometryReader { proxy in
            let windowWidth = proxy.size.width
            let live = liveDrag(windowWidth: windowWidth)
            let shown = live?.layout ?? layout
            let resolved = shown.resolved(windowWidth: windowWidth)
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.gap)
                if let width = resolved.sidebar {
                    PanelBox(fill: Tokens.Color.surfacePanel) { sidebar }
                        .frame(width: width)
                        .opacity(isPendingCollapse(.sidebar, live) ? Tokens.Opacity.disabled : 1)
                    divider(.sidebar, shown: shown, windowWidth: windowWidth)
                }
                PanelBox(fill: Tokens.Color.surfaceCanvas) { center }
                    .frame(width: resolved.center)
                if let width = resolved.detail {
                    divider(.detail, shown: shown, windowWidth: windowWidth)
                    PanelBox(fill: Tokens.Color.surfacePanel) { detail }
                        .frame(width: width)
                        .opacity(isPendingCollapse(.detail, live) ? Tokens.Opacity.disabled : 1)
                }
                Color.clear.frame(width: Self.gap)
            }
            .padding(.vertical, Self.gap)
        }
        .background(Tokens.Color.surfaceWindow)
        .frame(minWidth: layout.minimumWindowWidth)
        .focusedSceneValue(
            \.panelLayoutActions,
            PanelLayoutActions(
                isSidebarCollapsed: layout.isSidebarCollapsed,
                isDetailCollapsed: layout.isDetailCollapsed,
                toggle: { side in commit(layout.toggling(side), animated: true) }
            ))
    }

    // MARK: Drag

    private func liveDrag(windowWidth: CGFloat) -> PanelLayout.Drag? {
        guard let drag else { return nil }
        return layout.drag(drag.side, from: drag.startWidth, by: drag.translation, windowWidth: windowWidth)
    }

    private func isPendingCollapse(_ side: PanelLayout.Side, _ live: PanelLayout.Drag?) -> Bool {
        drag?.side == side && live?.isCollapsePending == true
    }

    private func divider(_ side: PanelLayout.Side, shown: PanelLayout, windowWidth: CGFloat) -> some View {
        PanelDivider(
            side: side,
            limitState: shown.limitState(side, windowWidth: windowWidth),
            accessibilityValue: shown.accessibilityValue(side, windowWidth: windowWidth),
            isDragging: drag?.side == side,
            onDragChanged: { translation in
                if drag == nil {
                    let start = layout.resolved(windowWidth: windowWidth).width(of: side) ?? layout.width(of: side)
                    drag = DragSession(side: side, startWidth: start, translation: translation)
                } else {
                    drag?.translation = translation
                }
            },
            onDragEnded: { translation in
                guard let session = drag else { return }
                let ended = layout.endDrag(
                    side, from: session.startWidth, by: translation, windowWidth: windowWidth)
                drag = nil
                // Following the pointer is never animated; only a collapse on release is.
                commit(ended, animated: ended.isCollapsed(side))
            },
            onReset: { commit(layout.reset(side), animated: false) },
            onStep: { steps in commit(layout.step(side, by: steps, windowWidth: windowWidth), animated: false) },
            onEdge: { edge in commit(layout.moveToEdge(side, edge, windowWidth: windowWidth), animated: false) }
        )
    }

    // MARK: Commit

    private func commit(_ new: PanelLayout, animated: Bool) {
        guard new != layout else { return }
        if animated, !reduceMotion {
            withAnimation(Self.collapseAnimation) { layout = new }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { layout = new }
        }
        onCommit(new)
    }

    /// Collapse and reopen: `motion.duration-standard` with `motion.easing-standard`.
    static var collapseAnimation: Animation {
        let curve = Tokens.Motion.easingStandardControlPoints
        return .timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: Tokens.Motion.durationStandard)
    }
}

// MARK: - Panel box

/// One rounded panel on the window background (art-direction.md §3: radius 10, 1px `border.panel`).
private struct PanelBox<Content: View>: View {
    let fill: Color
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(fill)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Tokens.Color.borderPanel, lineWidth: 1))
    }
}

// MARK: - Divider

/// The gutter between two panels: the whole 8pt-wide, full-height gutter is the hit area, with a 4×28 grip in the
/// middle (art-direction.md §3.2).
private struct PanelDivider: View {
    let side: PanelLayout.Side
    let limitState: PanelLayout.LimitState
    let accessibilityValue: String
    let isDragging: Bool
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void
    let onReset: () -> Void
    /// Positive widens the panel.
    let onStep: (Int) -> Void
    let onEdge: (PanelLayout.Edge) -> Void

    @State private var isHovering = false

    /// interaction.md §2.1: the hovered or dragged gutter gets the accent at 10%. No token yet (tokens.json describes
    /// `surface.hover` for it); kept here so the value has one home.
    static let gutterHighlightOpacity = 0.10

    private var isActive: Bool { isHovering || isDragging }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isActive ? Tokens.Color.accent.opacity(Self.gutterHighlightOpacity) : Color.clear)
            Capsule()
                .fill(isActive ? Tokens.Color.surfaceSplitterGripActive : Tokens.Color.surfaceSplitterGrip)
                .frame(width: Tokens.Size.splitterGrip.width, height: Tokens.Size.splitterGrip.height)
        }
        .frame(width: PanelLayout.gap)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovering = true
                cursor.set()
            case .ended:
                isHovering = false
                if !isDragging { NSCursor.arrow.set() }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    onDragChanged(value.translation.width)
                    cursor.set()
                }
                .onEnded { value in onDragEnded(value.translation.width) }
        )
        .onTapGesture(count: 2, perform: onReset)
        .focusable()
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            handle(press)
        }
        .accessibilityElement()
        .accessibilityLabel(side.accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onStep(1)
            case .decrement: onStep(-1)
            @unknown default: break
            }
        }
    }

    /// `→` moves the divider right: wider sidebar, narrower detail. `⌥` jumps to the end of the range.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let movesRight = press.key == .rightArrow
        let widens = movesRight == (side == .sidebar)
        if press.modifiers.contains(.option) {
            onEdge(widens ? .maximum : .minimum)
        } else {
            onStep(widens ? 1 : -1)
        }
        return .handled
    }

    /// `resizeLeftRight`, or the one direction that still moves at a limit.
    private var cursor: NSCursor {
        switch (side, limitState) {
        case (_, .between): .resizeLeftRight
        // Sidebar: widening moves the divider right.
        case (.sidebar, .atMinimum): .resizeRight
        case (.sidebar, .atMaximum): .resizeLeft
        // Detail: widening moves the divider left.
        case (.detail, .atMinimum): .resizeLeft
        case (.detail, .atMaximum): .resizeRight
        }
    }
}

// MARK: - Commands

/// What the focused window's `PanelSplitView` offers to menu commands.
struct PanelLayoutActions {
    let isSidebarCollapsed: Bool
    let isDetailCollapsed: Bool
    let toggle: @MainActor (PanelLayout.Side) -> Void
}

private struct PanelLayoutActionsKey: FocusedValueKey {
    typealias Value = PanelLayoutActions
}

extension FocusedValues {
    var panelLayoutActions: PanelLayoutActions? {
        get { self[PanelLayoutActionsKey.self] }
        set { self[PanelLayoutActionsKey.self] = newValue }
    }
}

/// View menu: Show/Hide Sidebar (`⌃⌘S`, the macOS standard) and Show/Hide Detail (`⌥⌘0`, the Xcode convention),
/// wired to the custom split container (ADR-0014, interaction.md §3.1). Disabled when no window has a split view.
struct PanelCommands: Commands {
    @FocusedValue(\.panelLayoutActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(actions?.isSidebarCollapsed == true ? "Show Sidebar" : "Hide Sidebar") {
                actions?.toggle(.sidebar)
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(actions == nil)

            Button(actions?.isDetailCollapsed == true ? "Show Detail" : "Hide Detail") {
                actions?.toggle(.detail)
            }
            .keyboardShortcut("0", modifiers: [.option, .command])
            .disabled(actions == nil)
        }
    }
}

// MARK: - Previews

private struct PanelSplitPreview: View {
    @State var layout: PanelLayout

    var body: some View {
        PanelSplitView(layout: $layout) {
            PreviewPanel(title: "Sidebar")
        } center: {
            PreviewPanel(title: "Graph")
        } detail: {
            PreviewPanel(title: "Detail")
        }
        .frame(width: 1440, height: 600)
    }
}

private struct PreviewPanel: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text(title).font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
            Text("Drag the gutter, double-click to reset, ⌃⌘S / ⌥⌘0 to collapse.")
                .font(Tokens.Font.body)
                .foregroundStyle(Tokens.Color.textSecondary)
        }
        .padding(Tokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview("Default") {
    PanelSplitPreview(layout: .default)
}

#Preview("Sidebar collapsed") {
    PanelSplitPreview(layout: PanelLayout.default.toggling(.sidebar))
}

#Preview("Dark") {
    PanelSplitPreview(layout: .default).preferredColorScheme(.dark)
}
