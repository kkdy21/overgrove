import AppKit
import XCTest

@testable import Overgrove

/// `⎋` where `onExitCommand` does not see it (#650): in the toolbar search field, and with nothing in the window
/// focused.
@MainActor
final class EscapeFocusMonitorTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func key(
        _ keyCode: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    func testOnlyAPlainEscapeCounts() throws {
        let window = window()
        XCTAssertTrue(EscapeFocusMonitor.isEscape(try key(53, "\u{1b}", in: window)))
        XCTAssertTrue(EscapeFocusMonitor.isEscape(try key(53, "\u{1b}", modifiers: .capsLock, in: window)))
        XCTAssertFalse(EscapeFocusMonitor.isEscape(try key(53, "\u{1b}", modifiers: .command, in: window)))
        XCTAssertFalse(EscapeFocusMonitor.isEscape(try key(0, "a", in: window)))
    }

    func testRoutes() {
        let window = window()
        let search = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        let filter = NSTextField(frame: NSRect(x: 0, y: 40, width: 200, height: 22))
        window.contentView?.addSubview(search)
        window.contentView?.addSubview(filter)

        XCTAssertEqual(EscapeFocusMonitor.route(isEscape: false, firstResponder: window, window: window), .pass)
        XCTAssertEqual(EscapeFocusMonitor.route(isEscape: true, firstResponder: window, window: window), .handle)
        XCTAssertEqual(EscapeFocusMonitor.route(isEscape: true, firstResponder: nil, window: window), .handle)

        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertEqual(
            EscapeFocusMonitor.route(isEscape: true, firstResponder: window.firstResponder, window: window),
            .passThenFocusGraph, "typing in the search field: \(String(describing: window.firstResponder))")

        // The sidebar filter clears itself on ⎋ (`onExitCommand`), and a focused list handles ⎋ through SwiftUI.
        XCTAssertTrue(window.makeFirstResponder(filter))
        XCTAssertEqual(
            EscapeFocusMonitor.route(isEscape: true, firstResponder: window.firstResponder, window: window), .pass)
        XCTAssertEqual(
            EscapeFocusMonitor.route(isEscape: true, firstResponder: window.contentView, window: window), .pass)
    }

    /// #709: while a screen covers the graph, `⎋` closes it wherever the focus is, unless text is being typed. A text
    /// view that only selects (a diff's lines) does not count as typing; the search field keeps its own route.
    func testWhileAScreenCoversTheGraphEscapeClosesItUnlessTextIsTyped() {
        let window = window()
        let view = FocusableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let filter = NSTextField(frame: NSRect(x: 0, y: 40, width: 200, height: 22))
        let search = NSSearchField(frame: NSRect(x: 0, y: 80, width: 200, height: 22))
        let selectable = NSTextView(frame: NSRect(x: 0, y: 120, width: 200, height: 40))
        selectable.isEditable = false
        let editable = NSTextView(frame: NSRect(x: 0, y: 160, width: 200, height: 40))
        for subview in [view, filter, search, selectable, editable] { window.contentView?.addSubview(subview) }

        func route(_ responder: NSResponder?, covered: Bool = true) -> EscapeFocusMonitor.Route {
            EscapeFocusMonitor.route(isEscape: true, firstResponder: responder, window: window, isGraphCovered: covered)
        }
        XCTAssertEqual(route(view), .closeScreen, "a view that holds the focus")
        XCTAssertEqual(route(selectable), .closeScreen, "selectable text is not typing")
        XCTAssertEqual(route(editable), .pass, "an editable text view keeps ⎋")
        XCTAssertEqual(route(window), .handle, "nothing focused: the window's ⎋, then the graph")
        XCTAssertTrue(window.makeFirstResponder(filter))
        XCTAssertEqual(route(window.firstResponder), .pass, "the sidebar filter clears itself on ⎋")
        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertEqual(route(window.firstResponder), .passThenFocusGraph)

        XCTAssertEqual(route(view, covered: false), .pass, "nothing covers the graph: SwiftUI handles ⎋")
        XCTAssertEqual(
            EscapeFocusMonitor.route(isEscape: false, firstResponder: view, window: window, isGraphCovered: true), .pass
        )
    }

    /// Closing a covering screen leaves the focus where it is: no move to the graph.
    func testClosingAScreenKeepsTheFocus() throws {
        let window = window()
        let monitor = EscapeFocusMonitor.MonitorView(frame: .zero)
        let list = FocusableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(monitor)
        window.contentView?.addSubview(list)
        var calls: [String] = []
        monitor.onEscape = { calls.append("escape") }
        monitor.onFocusGraph = { calls.append("graph") }
        monitor.isGraphCovered = { true }
        XCTAssertTrue(window.makeFirstResponder(list))

        XCTAssertTrue(monitor.consume(try key(53, "\u{1b}", in: window)))
        XCTAssertEqual(calls, ["escape"])
        XCTAssertFalse(monitor.consume(try key(0, "a", in: window)), "other keys pass")
        monitor.stop()
    }

    /// With nothing focused, `⎋` runs the window's handler, moves focus to the graph, and stops there.
    func testEscapeWithNothingFocusedIsHandled() throws {
        let window = window()
        let monitor = EscapeFocusMonitor.MonitorView(frame: .zero)
        window.contentView?.addSubview(monitor)
        var calls: [String] = []
        monitor.onEscape = { calls.append("escape") }
        monitor.onFocusGraph = { calls.append("graph") }
        window.makeFirstResponder(nil)

        XCTAssertFalse(monitor.consume(try key(0, "a", in: window)))
        XCTAssertTrue(monitor.consume(try key(53, "\u{1b}", in: window)))
        XCTAssertEqual(calls, ["escape", "graph"])
        monitor.stop()
    }

    /// In the search field `⎋` goes on to AppKit; the graph takes focus only once the field has let go of it.
    func testEscapeInTheSearchFieldFocusesTheGraphAfterTheFieldLetsGo() throws {
        let window = window()
        let search = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        let monitor = EscapeFocusMonitor.MonitorView(frame: .zero)
        window.contentView?.addSubview(search)
        window.contentView?.addSubview(monitor)
        var calls: [String] = []
        monitor.onEscape = { calls.append("escape") }
        monitor.onFocusGraph = { calls.append("graph") }

        // The field keeps focus (a ⎋ that only cleared the query): the graph does not take it.
        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertFalse(monitor.consume(try key(53, "\u{1b}", in: window)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(calls, [])

        // The field ends the search and hands focus to the window, as the toolbar field does.
        XCTAssertFalse(monitor.consume(try key(53, "\u{1b}", in: window)))
        window.makeFirstResponder(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(calls, ["graph"], "the window's own ⎋ handler is not run for the field's ⎋")
        monitor.stop()
    }
}

/// A view that takes the keyboard focus, standing in for SwiftUI's hosting view.
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
