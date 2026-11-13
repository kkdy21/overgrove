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
