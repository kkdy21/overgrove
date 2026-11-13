import AppKit
import SwiftUI

/// The main window's three-panel container (#174, ADR-0014, art-direction.md §3, interaction.md §2.1).
///
/// Sidebar, center, and detail are rounded panels on the window background, separated by 8pt gutters that act as
/// splitters. `PanelLayout` does all the width math; this view only draws it and turns pointer, keyboard, and
/// VoiceOver input into layout changes.
///
/// - `layout` is written when a change finishes; drag frames are kept in this view's own state.
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
                // Collapsed panels stay in the hierarchy at width 0, so their content keeps its state (selection,
                // scroll position) and the width animates instead of the view being removed and rebuilt.
                PanelBox(fill: Tokens.Color.surfacePanel) { sidebar }
                    .modifier(
                        CollapsiblePanel(width: resolved.sidebar, isPendingCollapse: isPendingCollapse(.sidebar, live)))
                if resolved.sidebar != nil {
                    divider(.sidebar, shown: shown, windowWidth: windowWidth)
                }
                PanelBox(fill: Tokens.Color.surfaceCanvas) { center }
                    .frame(width: resolved.center)
                if resolved.detail != nil {
                    divider(.detail, shown: shown, windowWidth: windowWidth)
                }
                PanelBox(fill: Tokens.Color.surfacePanel) { detail }
                    .modifier(
                        CollapsiblePanel(width: resolved.detail, isPendingCollapse: isPendingCollapse(.detail, live)))
                Color.clear.frame(width: Self.gap)
            }
            .padding(.vertical, Self.gap)
        }
        .background(Tokens.Color.surfaceWindow)
        // A cursor set over this window (a divider's resize cursor) must not stay when another window takes over (#648).
        .background(KeyWindowCursorReset())
        .frame(minWidth: layout.minimumWindowWidth)
        .focusedSceneValue(
            \.panelLayoutActions,
            PanelLayoutActions(
                isSidebarCollapsed: layout.isSidebarCollapsed,
                isDetailCollapsed: layout.isDetailCollapsed,
                toggle: { side in
                    drag = nil  // a collapse during a drag ends it; the gesture may never report an end
                    commit(layout.toggling(side), animated: true)
                }
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
                if drag?.side == side {
                    drag?.translation = translation
                } else {
                    // New drag, or a stale session from the other divider whose end was never reported.
                    let start = layout.resolved(windowWidth: windowWidth).width(of: side) ?? layout.width(of: side)
                    drag = DragSession(side: side, startWidth: start, translation: translation)
                }
            },
            onDragEnded: { translation in
                guard let session = drag, session.side == side else { return }
                let ended = layout.endDrag(
                    side, from: session.startWidth, by: translation, windowWidth: windowWidth)
                drag = nil
                // Following the pointer is never animated; only a collapse on release is.
                commit(ended, animated: ended.isCollapsed(side))
            },
            onDragCancelled: {
                // SwiftUI does not call `onEnded` for a cancelled gesture; drop the session without committing.
                if drag?.side == side { drag = nil }
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
            withAnimation(.panelCollapse) { layout = new }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { layout = new }
        }
        onCommit(new)
    }

}

extension Animation {
    /// Panel collapse and reopen: `motion.duration-standard` with `motion.easing-standard`. Callers skip it under
    /// Reduce Motion.
    static var panelCollapse: Animation { .standard }
}

// MARK: - Panel box

/// One rounded panel on the window background (art-direction.md §3): radius 10, 1px `border.panel`, a 1px top
/// highlight in dark mode (`surface.panel-highlight`) and a 1px shadow below in light mode (`surface.panel-shadow`).
/// Each token is transparent in the other mode, so both are always applied.
private struct PanelBox<Content: View>: View {
    let fill: Color
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(fill)
            .overlay(alignment: .top) {
                Tokens.Color.surfacePanelHighlight.frame(height: 1).padding(.top, 1).allowsHitTesting(false)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Tokens.Color.borderPanel, lineWidth: 1))
            // Drawn from the shape only: `.shadow` on the panel would shadow every glyph inside it.
            .background { shape.fill(Tokens.Color.surfacePanelShadow).offset(y: 1) }
    }
}

// MARK: - Divider

/// The gutter between two panels: the whole 8pt-wide, full-height gutter is the hit area, with a 4×28 grip in the
/// middle (art-direction.md §3.2).
struct PanelDivider: View {
    let side: PanelLayout.Side
    let limitState: PanelLayout.LimitState
    let accessibilityValue: String
    let isDragging: Bool
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void
    let onDragCancelled: () -> Void
    let onReset: () -> Void
    /// Positive widens the panel.
    let onStep: (Int) -> Void
    let onEdge: (PanelLayout.Edge) -> Void

    /// The pointer is over the gutter, as the window's `WindowCursorArbiter` decided (#656).
    @State private var isPointerOver = false
    /// The gutter's frame in the window, so the arbiter decides again when the layout moved it.
    @State private var gutterFrame: CGRect = .zero
    /// True while the drag gesture runs; SwiftUI resets it on end *and* on cancel, unlike `onEnded`.
    @GestureState private var isGestureActive = false

    /// interaction.md §2.1: the hovered or dragged gutter gets the accent at 10%. No opacity token; tokens.json describes it in
    /// `splitter-grip-active`; kept here so the value has one home.
    static let gutterHighlightOpacity = 0.10

    private var isActive: Bool { isPointerOver || isDragging }

    var body: some View {
        ZStack {
            // Only the colours fade in `motion.duration-fast` (#571); the divider itself follows the pointer with no
            // animation, including on the frame where a drag starts or ends.
            Rectangle()
                .fill(isActive ? Tokens.Color.accent.opacity(Self.gutterHighlightOpacity) : Color.clear)
                .motion(.fast, value: isActive)
            Capsule()
                .fill(isActive ? Tokens.Color.surfaceSplitterGripActive : Tokens.Color.surfaceSplitterGrip)
                .motion(.fast, value: isActive)
                .frame(width: Tokens.Size.splitterGrip.width, height: Tokens.Size.splitterGrip.height)
        }
        .frame(width: PanelLayout.gap)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            gutterFrame = $0
        }
        // The resize cursor, as NSSplitView shows: only in the key window, gone when the pointer leaves; a drag keeps
        // it. The window's one `WindowCursorArbiter` decides it from the real pointer, not SwiftUI hover and
        // `pointerStyle`, whose state went stale across key changes and collapses (#656).
        .background(
            DividerCursorRegion(
                cursor: cursor, isDragging: isDragging, layoutKey: gutterFrame,
                onPointerOver: { isPointerOver = $0 })
        )
        .gesture(
            // 3pt so a slightly jittery double-click on a trackpad is not taken for a drag.
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .updating($isGestureActive) { _, active, _ in active = true }
                .onChanged { value in
                    onDragChanged(value.translation.width)
                    cursor.set()  // keep the resize cursor while the pointer leaves the 8pt gutter
                }
                .onEnded { value in
                    // The arbiter then sets the cursor for where the pointer was released (#648).
                    onDragEnded(value.translation.width)
                }
        )
        .onChange(of: isGestureActive) { _, active in
            guard !active else { return }
            // After a normal end `onEnded` has already cleared the session, so this is a no-op; after a cancel
            // (e.g. the divider disappeared mid-drag) it is the only signal. Deferred so it never races `onEnded`.
            Task { @MainActor in onDragCancelled() }
        }
        .onTapGesture(count: 2, perform: onReset)
        // Focus only through keyboard navigation; a click on the gutter must not steal focus from the panels.
        .focusable(interactions: .activate)
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
        // Only plain and ⌥ arrows; ⌘/⌃/⇧ arrows belong to someone else.
        guard press.modifiers.isDisjoint(with: [.command, .control, .shift]) else { return .ignored }
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

// MARK: - Collapsing and cursor helpers

/// Width for a panel that may be collapsed: at width 0 it is invisible, ignored by VoiceOver, untouchable, and
/// disabled (so focus cannot move into it), but it stays in the view hierarchy.
private struct CollapsiblePanel: ViewModifier {
    let width: CGFloat?
    let isPendingCollapse: Bool

    func body(content: Content) -> some View {
        let isCollapsed = width == nil
        content
            .frame(width: width ?? 0)
            .clipped()
            .opacity(isCollapsed ? 0 : (isPendingCollapse ? Tokens.Opacity.disabled : 1))
            .accessibilityHidden(isCollapsed)
            .allowsHitTesting(!isCollapsed)
            .disabled(isCollapsed)
    }
}

/// A pointer cursor over a view (#634): the resize cursors on the graph column dividers, the pointing hand on clickable
/// status bar fields. The panel dividers use `WindowCursorArbiter` instead (#656).
///
/// macOS 15 and later: SwiftUI's `pointerStyle`, which follows the window's key state and the pointer leaving.
/// macOS 14: `CursorArea`. An `NSView` cursor rect alone lost to the hosting view: AppKit sends cursor updates to the
/// view under the pointer, and the cursor view must not take hits (it would swallow the clicks and drags), so the
/// SwiftUI hosting view set the arrow back. `CursorArea` also tracks the pointer itself and sets its cursor on enter
/// and move, the arrow on exit.
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        modifier(CursorModifier(cursor: cursor))
    }
}

struct CursorModifier: ViewModifier {
    let cursor: NSCursor

    func body(content: Content) -> some View {
        if #available(macOS 15, *), let style = Self.pointerStyle(for: cursor) {
            content.pointerStyle(style)
        } else {
            content.background(CursorArea(cursor: cursor))
        }
    }

    /// The SwiftUI style for the AppKit cursors the app uses; `nil` for any other, which falls back to `CursorArea`.
    @available(macOS 15, *)
    static func pointerStyle(for cursor: NSCursor) -> PointerStyle? {
        switch cursor {
        case .resizeLeftRight: .columnResize
        case .resizeLeft: .columnResize(directions: .leading)
        case .resizeRight: .columnResize(directions: .trailing)
        case .pointingHand: .link
        default: nil
        }
    }
}

struct CursorArea: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorView {
        CursorView()
    }

    func updateNSView(_ view: CursorView, context: Context) {
        view.cursor = cursor
    }

    final class CursorView: NSView {
        var cursor: NSCursor = .arrow {
            didSet {
                guard cursor !== oldValue else { return }
                window?.invalidateCursorRects(for: self)
                if isInside { cursor.set() }
            }
        }
        private(set) var isInside = false

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
        }

        /// Enter, move, and exit come to the area's owner whatever is under the pointer, so they work although this
        /// view takes no hits. Only in the key window, like the cursor rect.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                    owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            isInside = true
            cursor.set()
        }

        /// Again on every move: the hosting view under the pointer may set the arrow back.
        override func mouseMoved(with event: NSEvent) {
            if isInside { cursor.set() }
        }

        override func mouseExited(with event: NSEvent) {
            isInside = false
            NSCursor.arrow.set()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil, isInside {
                isInside = false
                NSCursor.arrow.set()
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

/// Puts the arrow back when another window of the app becomes key (#648), such as Settings. This window's cursors
/// (`View.cursor`) only work while it is key: without this, a divider's resize cursor stayed while the pointer crossed
/// this window and after Settings closed, until the pointer moved again. Nothing happens while another app becomes
/// active, so its cursor is never touched.
struct KeyWindowCursorReset: NSViewRepresentable {
    func makeNSView(context: Context) -> ResetView { ResetView() }

    func updateNSView(_ view: ResetView, context: Context) {}

    final class ResetView: NSView {
        private var observer: NSObjectProtocol?
        /// Windows that keep their own cursors right (they host a `ResetView` and a `WindowCursorArbiter`): another
        /// main window becoming key is left to its arbiter, which would lose to this arrow (#656).
        static let managedWindows = NSHashTable<NSWindow>.weakObjects()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            Self.managedWindows.add(window)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { [weak self] note in
                let other = note.object as? NSWindow
                MainActor.assumeIsolated { self?.windowBecameKey(other) }
            }
        }

        /// `other` became key: the arrow, unless it is this view's own window or the app is not active.
        func windowBecameKey(_ other: NSWindow?, appIsActive: Bool = NSApp.isActive) {
            guard let window, let other, other !== window, appIsActive, !Self.managedWindows.contains(other) else {
                return
            }
            NSCursor.arrow.set()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A panel divider's area, for its window's `WindowCursorArbiter` (#656). Takes no hits.
struct DividerCursorRegion: NSViewRepresentable {
    let cursor: NSCursor
    let isDragging: Bool
    /// Changes when the layout may have moved the gutter under a still pointer (the gutter's frame).
    let layoutKey: CGRect
    let onPointerOver: (Bool) -> Void

    func makeNSView(context: Context) -> RegionView { RegionView() }

    func updateNSView(_ view: RegionView, context: Context) {
        view.onPointerOver = onPointerOver
        view.cursor = cursor
        let dragEnded = view.isDragging && !isDragging
        view.isDragging = isDragging
        // Not on every update: only a moved gutter or a finished drag can change what is under the pointer.
        if dragEnded || view.layoutKey != layoutKey {
            view.layoutKey = layoutKey
            view.arbiter?.scheduleEvaluation()
        }
    }

    final class RegionView: NSView {
        var cursor: NSCursor = .resizeLeftRight
        var isDragging = false
        var layoutKey: CGRect?
        var onPointerOver: (Bool) -> Void = { _ in }
        private(set) var isPointerOver = false
        private(set) weak var arbiter: WindowCursorArbiter?

        func setPointerOver(_ over: Bool) {
            guard over != isPointerOver else { return }
            isPointerOver = over
            onPointerOver(over)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            arbiter?.remove(self)
            arbiter = window.map(WindowCursorArbiter.arbiter(for:))
            arbiter?.add(self)
        }

        /// Enter, move, and exit come to the area's owner whatever is under the pointer, so they work although this
        /// view takes no hits. Only in the key window.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                    owner: self))
        }

        override func mouseEntered(with event: NSEvent) { arbiter?.scheduleEvaluation() }
        override func mouseMoved(with event: NSEvent) { arbiter?.scheduleEvaluation() }
        override func mouseExited(with event: NSEvent) { arbiter?.scheduleEvaluation() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The one judge of the panel dividers' cursor in a window (#656).
///
/// Each divider deciding its own cursor from SwiftUI hover and `pointerStyle` lost in turn: hover misses an exit while
/// the window is not key and when a collapse moves the gutter away, a style left on came back after Settings closed or
/// a collapse ended, a style turned off missed the event the pointer entered on, and a newly key window got SwiftUI's
/// arrow about half a second later. The arbiter knows every divider in the window and sets one cursor from the real
/// pointer (`mouseLocationOutsideOfEventStream`):
/// - over a divider, or during a divider drag: that divider's cursor, set every time, so it wins over a late arrow;
/// - elsewhere: the arrow, but only while the divider cursor it last set is still showing, so a cursor someone else set
///   (a text view's I-beam, a graph column divider) is left alone.
///
/// It decides after each event that can change the answer, once the event has been handled: the pointer entering,
/// moving over, or leaving a divider, a cursor update (the hosting view's arrow), the mouse button going up, a divider
/// moved by the layout or removed, and the window becoming key (again over the next second) or resigning.
@MainActor
final class WindowCursorArbiter {
    private static let arbiters = NSMapTable<NSWindow, WindowCursorArbiter>.weakToStrongObjects()
    /// The divider cursor an arbiter last set, app-wide: a cursor set in one main window is still showing when another
    /// becomes key.
    private static var shownCursor: NSCursor?
    private static var eventMonitor: Any?

    /// After the window becomes key, decided again at these delays (seconds): SwiftUI sets the arrow for a newly key
    /// window as late as half a second after.
    static let keyFollowUps: [TimeInterval] = [0.1, 0.3, 0.6, 1.0]

    static func arbiter(for window: NSWindow) -> WindowCursorArbiter {
        if let arbiter = arbiters.object(forKey: window) { return arbiter }
        let arbiter = WindowCursorArbiter(window: window)
        arbiters.setObject(arbiter, forKey: window)
        installEventMonitor()
        return arbiter
    }

    /// The pointer in window coordinates; a test hands in its own.
    var pointerLocation: (() -> NSPoint)?
    /// The window is key and the app active; a test hands in its own.
    var isWindowKey: (() -> Bool)?
    /// The left mouse button is down, so a divider drag is still running; a test hands in its own.
    var isMouseDown: (() -> Bool)?

    private weak var window: NSWindow?
    private let regions = NSHashTable<DividerCursorRegion.RegionView>.weakObjects()
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    private init(window: NSWindow) {
        self.window = window
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleEvaluation(followUps: Self.keyFollowUps) }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleEvaluation() }
            })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Cursor updates (the hosting view setting the arrow) and the mouse button going up, for the window they happen in.
    private static func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.cursorUpdate, .leftMouseUp]) { event in
            MainActor.assumeIsolated { handle(event, in: event.window ?? NSApp.keyWindow) }
            return event
        }
    }

    /// A cursor update or mouse up in `window`: its arbiter decides again once the event has been handled.
    static func handle(_ event: NSEvent, in window: NSWindow?) {
        guard let window else { return }
        arbiters.object(forKey: window)?.scheduleEvaluation()
    }

    func add(_ region: DividerCursorRegion.RegionView) {
        regions.add(region)
        scheduleEvaluation()
    }

    func remove(_ region: DividerCursorRegion.RegionView) {
        regions.remove(region)
        region.setPointerOver(false)
        scheduleEvaluation()
    }

    /// Decides once the current event and layout pass are done, then again at each of `followUps`.
    func scheduleEvaluation(followUps: [TimeInterval] = []) {
        for delay in [0] + followUps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
    }

    func evaluate() {
        let all = regions.allObjects.filter { $0.window != nil && $0.window === window }
        guard let window, isWindowKey?() ?? (window.isKeyWindow && NSApp.isActive) else {
            // Not key: no highlight, and the cursor belongs to the window that is (Settings gets the arrow from
            // `KeyWindowCursorReset`).
            for region in all { region.setPointerOver(false) }
            return
        }
        let location = pointerLocation?() ?? window.mouseLocationOutsideOfEventStream
        let hit = all.first { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.contains($0.convert(location, from: nil)) }
        let isMouseDown = isMouseDown?() ?? (NSEvent.pressedMouseButtons & 1 != 0)
        // A drag whose divider was removed by a collapse never reports its end, so a drag counts only while the button
        // is down.
        let dragging = isMouseDown ? all.first(where: \.isDragging) : nil
        for region in all { region.setPointerOver(region === hit) }
        if let cursor = (dragging ?? hit)?.cursor {
            Self.shownCursor = cursor
            cursor.set()
        } else if let shown = Self.shownCursor {
            Self.shownCursor = nil
            if NSCursor.current == shown { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Commands

/// What the focused window's `PanelSplitView` offers to menu commands.
struct PanelLayoutActions: Equatable {
    let isSidebarCollapsed: Bool
    let isDetailCollapsed: Bool
    let toggle: @MainActor (PanelLayout.Side) -> Void

    /// Equal when the menu would look the same, so ordinary re-renders do not republish the focused value.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isSidebarCollapsed == rhs.isSidebarCollapsed && lhs.isDetailCollapsed == rhs.isDetailCollapsed
    }
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
