import AppKit
import SwiftUI

/// `⎋` where SwiftUI's `onExitCommand` does not see it (#650). The toolbar search field is AppKit's: `⎋` there clears
/// the query and hands keyboard focus to the window itself, and with nothing focused in the window the next `⎋` reached
/// no handler. So a local key monitor on this window:
///
/// - lets `⎋` in the search field through, and once the field has let go of focus, gives it to the graph, so the next
///   `⎋` goes on down interaction.md §3.1's order;
/// - handles `⎋` itself when the window holds focus and nothing in it does: the window's `⎋` (`AppState.escape`), and
///   focus to the graph.
///
/// Every other key, and `⎋` anywhere else, passes untouched. It takes no mouse events (`hitTest` returns nil).
struct EscapeFocusMonitor: NSViewRepresentable {
    let onEscape: () -> Void
    let onFocusGraph: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onEscape = onEscape
        view.onFocusGraph = onFocusGraph
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
    }

    /// `⎋` with no modifiers (Caps Lock and Fn do not matter).
    nonisolated static func isEscape(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53 else { return false }
        return event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
    }

    @MainActor
    static func route(isEscape: Bool, firstResponder: NSResponder?, window: NSWindow) -> Route {
        guard isEscape else { return .pass }
        if isEditingSearchField(firstResponder) { return .passThenFocusGraph }
        if firstResponder == nil || firstResponder === window { return .handle }
        return .pass
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
            switch EscapeFocusMonitor.route(
                isEscape: EscapeFocusMonitor.isEscape(event), firstResponder: window.firstResponder, window: window)
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
            }
        }
    }
}
