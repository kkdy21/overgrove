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
}
