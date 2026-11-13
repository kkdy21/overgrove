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

    private func offscreenWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: true)
    }

    /// #656: the divider's probe answers from the real pointer, not from hover: over it only in a key window of the
    /// active app, and not once the layout moved it away from a pointer that stayed still.
    func testTheProbeChecksTheRealPointer() throws {
        let window = offscreenWindow()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        defer { window.contentView = nil }
        let probe = PointerProbe.ProbeView(frame: NSRect(x: 300, y: 0, width: 8, height: 300))
        content.addSubview(probe)
        var pointer = NSPoint(x: 304, y: 150)
        var isKey = true
        probe.pointerLocation = { pointer }
        probe.isWindowKey = { isKey }
        var reports: [Bool] = []
        probe.onCheck = { reports.append($0) }

        XCTAssertTrue(probe.isPointerInside(), "a window that became key with the pointer already there")
        pointer = NSPoint(x: 200, y: 150)
        XCTAssertFalse(probe.isPointerInside(), "the pointer left while another window was key")
        pointer = NSPoint(x: 304, y: 150)
        probe.setFrameOrigin(NSPoint(x: 120, y: 0))
        XCTAssertFalse(probe.isPointerInside(), "a collapse moved the gutter away from the still pointer")
        probe.setFrameOrigin(NSPoint(x: 300, y: 0))
        isKey = false
        XCTAssertFalse(probe.isPointerInside(), "never in a window that is not key")
        isKey = true
        probe.check()
        XCTAssertEqual(reports, [true])
        XCTAssertNil(probe.hitTest(NSPoint(x: 304, y: 150)), "takes no clicks or drags")
    }

    /// #656: another main window becoming key keeps its own cursor (its probes set it); only a window without them
    /// (Settings) gets the arrow.
    func testAnotherMainWindowKeepsItsOwnCursor() {
        let first = offscreenWindow()
        let second = offscreenWindow()
        let settings = offscreenWindow()
        let firstReset = KeyWindowCursorReset.ResetView(frame: .zero)
        let secondReset = KeyWindowCursorReset.ResetView(frame: .zero)
        first.contentView = firstReset
        second.contentView = secondReset
        defer {
            first.contentView = nil
            second.contentView = nil
        }
        NSCursor.resizeLeft.set()
        firstReset.windowBecameKey(second, appIsActive: true)
        XCTAssertEqual(NSCursor.current, .resizeLeft, "the other main window sets its own cursor")
        firstReset.windowBecameKey(settings, appIsActive: true)
        XCTAssertEqual(NSCursor.current, .arrow)
    }

    /// #656: the divider's pointer style stays on, so it is there for the event the pointer enters on (with it off
    /// until hover said "over", the first event showed the arrow and a pointer that stopped there kept it). It is off
    /// only after the pointer was found gone behind hover's back, until hover reports again.
    func testTheStyleIsOnForTheEnterAndOffOnlyWhileHoverIsStale() {
        var pointer = DividerPointer()
        XCTAssertTrue(pointer.isStyleOn, "on before the pointer ever entered")
        XCTAssertEqual(pointer.hover(true, cursor: .resizeLeftRight), .enter(.resizeLeftRight))
        XCTAssertTrue(pointer.isOver)
        XCTAssertEqual(pointer.hover(false, cursor: .resizeLeftRight), .none, "SwiftUI sets the arrow on its exit")
        XCTAssertTrue(pointer.isStyleOn, "a normal exit leaves the style on for the next enter")

        // Settings opened over the gutter: the window stops being key, the pointer leaves unseen, Settings closes.
        _ = pointer.hover(true, cursor: .resizeLeft)
        XCTAssertEqual(pointer.check(false, cursor: .resizeLeft, isDragging: false), .set(.arrow))
        XCTAssertFalse(pointer.isStyleOn, "off, or it comes back when the window is key again")
        XCTAssertEqual(pointer.check(false, cursor: .resizeLeft, isDragging: false), .none)
        XCTAssertFalse(pointer.isStyleOn)
        XCTAssertEqual(pointer.hover(true, cursor: .resizeLeft), .enter(.resizeLeft), "hover is current again")
        XCTAssertTrue(pointer.isStyleOn)

        // Settings closed with the pointer still on the gutter.
        _ = pointer.check(false, cursor: .resizeLeft, isDragging: false)
        XCTAssertEqual(pointer.check(true, cursor: .resizeLeft, isDragging: false), .set(.resizeLeft))
        XCTAssertTrue(pointer.isStyleOn)
        XCTAssertTrue(pointer.isOver)
    }

    /// #656: a check that finds the pointer over the gutter sets the cursor every time, also when the divider already
    /// thought so: the enter that came while the other main window was key set nothing.
    func testAWindowThatBecomesKeySetsTheCursorUnderAStillPointer() {
        var pointer = DividerPointer()
        XCTAssertEqual(pointer.check(true, cursor: .resizeLeftRight, isDragging: false), .set(.resizeLeftRight))
        XCTAssertEqual(pointer.check(true, cursor: .resizeLeftRight, isDragging: false), .set(.resizeLeftRight))
        XCTAssertEqual(
            pointer.check(false, cursor: .resizeLeftRight, isDragging: true), .none, "a drag keeps its cursor")
        XCTAssertTrue(pointer.isOver)
        XCTAssertTrue(pointer.isStyleOn)
    }

    /// #656: a drag released off the gutter (a collapse, a limit) turns the style off like a missed exit; released on
    /// it, the style stays.
    func testADragReleasedOffTheGutterTurnsTheStyleOff() {
        var pointer = DividerPointer()
        _ = pointer.hover(true, cursor: .resizeLeftRight)
        XCTAssertEqual(pointer.dragEnded(inside: false, cursor: .resizeLeftRight), .set(.arrow))
        XCTAssertFalse(pointer.isOver)
        XCTAssertFalse(pointer.isStyleOn)
        XCTAssertEqual(pointer.dragEnded(inside: true, cursor: .resizeRight), .set(.resizeRight))
        XCTAssertTrue(pointer.isOver)
        XCTAssertTrue(pointer.isStyleOn)
    }

    /// #656: the probe checks once the window becomes key and again after SwiftUI's own cursor update for it; a hover
    /// re-render alone (same gutter frame) does not check.
    func testTheProbeChecksAgainAfterTheWindowBecomesKey() throws {
        let window = offscreenWindow()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        defer { window.contentView = nil }
        let probe = PointerProbe.ProbeView(frame: NSRect(x: 300, y: 0, width: 8, height: 300))
        probe.pointerLocation = { NSPoint(x: 304, y: 150) }
        probe.isWindowKey = { true }
        content.addSubview(probe)
        var reports = 0
        probe.onCheck = { _ in reports += 1 }
        drain(seconds: 0.05)
        reports = 0

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        drain(seconds: (PointerProbe.ProbeView.followUpDelays.last ?? 0) + 0.2)
        XCTAssertEqual(reports, 1 + PointerProbe.ProbeView.followUpDelays.count)

        reports = 0
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        drain(seconds: 0.05)
        XCTAssertEqual(reports, 1)
    }

    /// #656: an update with the same gutter frame (the highlight re-render after an enter) does not check; a moved
    /// gutter does. A check there could disagree with hover on the edge pixel and take the cursor away.
    func testTheProbeChecksOnlyWhenTheGutterMoved() {
        let window = offscreenWindow()
        var reports = 0
        let frame = CGRect(x: 300, y: 0, width: 8, height: 300)
        let host = NSHostingView(rootView: PointerProbe(layoutKey: frame, onCheck: { _ in reports += 1 }))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        drain(seconds: 0.05)
        reports = 0

        host.rootView = PointerProbe(layoutKey: frame, onCheck: { _ in reports += 1 })
        host.layoutSubtreeIfNeeded()
        drain(seconds: 0.05)
        XCTAssertEqual(reports, 0, "same frame")

        host.rootView = PointerProbe(layoutKey: frame.offsetBy(dx: -180, dy: 0), onCheck: { _ in reports += 1 })
        host.layoutSubtreeIfNeeded()
        drain(seconds: 0.05)
        XCTAssertEqual(reports, 1, "the gutter moved")
    }

    private func drain(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
