import AppKit
import SwiftUI

/// `⎋` where SwiftUI's `onExitCommand` does not see it (#650). The toolbar search field is AppKit's: `⎋` there clears
/// the query and hands keyboard focus to the window itself, and with nothing focused in the window the next `⎋` reached
/// no handler. So a local key monitor on this window:
///
/// - lets `⎋` in the search field through, and once the field has let go of focus, gives it to the graph, so the next
///   `⎋` goes on down interaction.md §3.1's order;
/// - handles `⎋` itself when the window holds focus and nothing in it does: the window's `⎋` (`AppState.escape`), and
///   focus to the graph;
/// - handles `⎋` itself while a screen covers the graph (S-09 to S-12), unless text is being typed: the window's `⎋`
///   closes the screen, and the focus stays where it is (#709). Such a screen often opens in the place of the focused
///   graph or S-09, and the focus SwiftUI is left with may take no key events at all, so `onExitCommand` never ran.
///
/// Every other key, and `⎋` anywhere else, passes untouched. It takes no mouse events (`hitTest` returns nil).
struct EscapeFocusMonitor: NSViewRepresentable {
    let onEscape: () -> Void
    let onFocusGraph: () -> Void
    /// `AppState.isGraphCovered`, asked when `⎋` arrives.
    var isGraphCovered: () -> Bool = { false }

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onEscape = onEscape
        view.onFocusGraph = onFocusGraph
        view.isGraphCovered = isGraphCovered
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stop()
    }

    /// What a key-down does in this window.
    enum Route: Equatable {
        /// Not ours: the event goes on as usual.
        case pass
        /// `⎋` in the search field: AppKit ends the search, then the graph takes focus.
        case passThenFocusGraph
        /// `⎋` with nothing focused: the window's `⎋`, then the graph takes focus; the event stops here.
        case handle
        /// `⎋` while a screen covers the graph and no text is being typed: the window's `⎋` closes the screen, and the
        /// focus stays; the event stops here (#709).
        case closeScreen
    }

    /// `⎋` with no modifiers (Caps Lock and Fn do not matter).
    nonisolated static func isEscape(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53 else { return false }
        return event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
    }

    @MainActor
    static func route(
        isEscape: Bool, firstResponder: NSResponder?, window: NSWindow, isGraphCovered: Bool = false
    ) -> Route {
        guard isEscape else { return .pass }
        if isEditingSearchField(firstResponder) { return .passThenFocusGraph }
        if firstResponder == nil || firstResponder === window { return .handle }
        if isGraphCovered, !isEditingText(firstResponder) { return .closeScreen }
        return .pass
    }

    /// Text is being typed: a field editor or another editable text view (the sidebar filter clears itself on `⎋`). A
    /// text view that only selects, such as a diff's lines, does not count.
    @MainActor
    static func isEditingText(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextField
    }

    /// The search field is being typed in: the window's field editor is first responder on its behalf.
    @MainActor
    static func isEditingSearchField(_ responder: NSResponder?) -> Bool {
        guard let editor = responder as? NSText, editor.isFieldEditor else { return responder is NSSearchField }
        return editor.delegate is NSSearchField
    }

    /// The search field has let go of focus: nothing in the window holds it.
    @MainActor
    static func hasNoFocus(_ window: NSWindow) -> Bool {
        window.firstResponder == nil || window.firstResponder === window
    }

    final class MonitorView: NSView {
        var onEscape: () -> Void = {}
        var onFocusGraph: () -> Void = {}
        var isGraphCovered: () -> Bool = { false }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Local monitors run on the main thread.
                let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// `true` when the event stops here.
        func consume(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            let isEscape = EscapeFocusMonitor.isEscape(event)
            switch EscapeFocusMonitor.route(
                isEscape: isEscape, firstResponder: window.firstResponder, window: window,
                isGraphCovered: isEscape && isGraphCovered())
            {
            case .pass:
                return false
            case .passThenFocusGraph:
                // The field handles the key first; look once it has.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window, EscapeFocusMonitor.hasNoFocus(window) else { return }
                    self.onFocusGraph()
                }
                return false
            case .handle:
                onEscape()
                onFocusGraph()
                return true
            case .closeScreen:
                onEscape()
                return true
            }
        }
    }
}
