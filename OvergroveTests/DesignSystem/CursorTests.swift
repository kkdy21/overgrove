import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// #634: the dividers' resize cursors and the status bar's pointing hand never showed. macOS 15 and later use
/// SwiftUI's `pointerStyle`; macOS 14 falls back to `CursorArea`, which tracks the pointer itself. Real pointer
/// checks are done by hand; these pin the mapping and the fallback's event handling.
@MainActor
final class CursorTests: XCTestCase {
    func testEveryCursorTheAppUsesHasAPointerStyle() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("pointerStyle needs macOS 15") }
        for cursor in [NSCursor.resizeLeftRight, .resizeLeft, .resizeRight, .pointingHand] {
            XCTAssertNotNil(CursorModifier.pointerStyle(for: cursor), "\(cursor)")
        }
        XCTAssertNil(CursorModifier.pointerStyle(for: .crosshair), "anything else falls back to CursorArea")
    }

    /// The fallback takes no hits (the clicks and drags go to SwiftUI), tracks the pointer in the key window, and
    /// sets its cursor on enter and move and the arrow on exit.
    func testTheFallbackTracksThePointerWithoutTakingHits() throws {
        let view = CursorArea.CursorView(frame: NSRect(x: 0, y: 0, width: 8, height: 100))
        view.cursor = .resizeLeftRight
        XCTAssertNil(view.hitTest(NSPoint(x: 4, y: 50)))
        view.updateTrackingAreas()
        let area = try XCTUnwrap(view.trackingAreas.first { $0.owner === view })
        XCTAssertTrue(area.options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(area.options.contains(.mouseMoved))
        XCTAssertTrue(area.options.contains(.activeInKeyWindow))
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.filter { $0.owner === view }.count, 1, "not added twice")

        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0))
        view.mouseEntered(with: event)
        XCTAssertTrue(view.isInside)
        XCTAssertEqual(NSCursor.current, .resizeLeftRight)
        NSCursor.arrow.set()
        view.mouseMoved(with: event)
        XCTAssertEqual(NSCursor.current, .resizeLeftRight, "set again when the hosting view put the arrow back")
        view.cursor = .resizeRight
        XCTAssertEqual(NSCursor.current, .resizeRight, "a cursor change inside shows at once")
        view.mouseExited(with: event)
        XCTAssertFalse(view.isInside)
        XCTAssertEqual(NSCursor.current, .arrow)
        view.mouseMoved(with: event)
        XCTAssertEqual(NSCursor.current, .arrow, "no cursor after the pointer left")
    }

    /// #648: a released divider drag keeps the resize cursor while the pointer is over the gutter, and shows the
    /// arrow once it is not (it used to set the arrow either way).
    func testAReleasedDragKeepsTheResizeCursorOverTheGutter() {
        let gutter = CGRect(x: 300, y: 8, width: 8, height: 600)
        XCTAssertEqual(
            PanelDivider.cursorAfterDrag(.resizeLeftRight, pointer: CGPoint(x: 304, y: 200), gutter: gutter),
            .resizeLeftRight)
        XCTAssertEqual(
            PanelDivider.cursorAfterDrag(.resizeRight, pointer: CGPoint(x: 304, y: 590), gutter: gutter), .resizeRight)
        XCTAssertEqual(
            PanelDivider.cursorAfterDrag(.resizeLeftRight, pointer: CGPoint(x: 380, y: 200), gutter: gutter), .arrow,
            "stopped at a limit, the pointer went on")
        XCTAssertEqual(
            PanelDivider.cursorAfterDrag(.resizeLeftRight, pointer: CGPoint(x: 304, y: 700), gutter: gutter), .arrow)
    }

    /// #648: when another window of the app becomes key (Settings), the main window's resize cursor does not stay;
    /// its own key change and another app's activation leave the cursor alone.
    func testAnotherKeyWindowPutsTheArrowBack() {
        let main = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 200), styleMask: [.titled],
            backing: .buffered, defer: true)
        let settings = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 200), styleMask: [.titled],
            backing: .buffered, defer: true)
        let view = KeyWindowCursorReset.ResetView(frame: .zero)
        main.contentView = view
        defer { main.contentView = nil }

        NSCursor.resizeLeftRight.set()
        view.windowBecameKey(main, appIsActive: true)
        XCTAssertEqual(NSCursor.current, .resizeLeftRight, "its own window")
        view.windowBecameKey(settings, appIsActive: false)
        XCTAssertEqual(NSCursor.current, .resizeLeftRight, "another app is active")
        view.windowBecameKey(settings, appIsActive: true)
        XCTAssertEqual(NSCursor.current, .arrow)
        XCTAssertNil(view.hitTest(.zero), "takes no clicks")
    }
}
