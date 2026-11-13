import AppKit
import XCTest

@testable import Overgrove

/// #656: the panel dividers' cursor comes from one judge per window, `WindowCursorArbiter`. These fix every case found
/// with the real pointer: entering by one pixel, stopping right after a fast approach, switching between two main
/// windows both ways, a newly opened window becoming key, closing Settings, collapsing a panel by dragging, and
/// releasing a drag on the divider. Windows are offscreen and never ordered front; the pointer, key state, and mouse
/// button are handed in.
@MainActor
final class WindowCursorArbiterTests: XCTestCase {
    /// A main window with the sidebar divider at x 300 and the detail divider at x 1000.
    @MainActor
    private final class MainWindow {
        let window: NSWindow
        let sidebar = DividerCursorRegion.RegionView(frame: NSRect(x: 300, y: 0, width: 8, height: 600))
        let detail = DividerCursorRegion.RegionView(frame: NSRect(x: 1000, y: 0, width: 8, height: 600))
        var pointer = NSPoint(x: 600, y: 300)
        var isKey = false
        var isMouseDown = false

        init() {
            window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 1300, height: 600), styleMask: [.titled],
                backing: .buffered, defer: true)
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1300, height: 600))
            let arbiter = WindowCursorArbiter.arbiter(for: window)
            arbiter.pointerLocation = { [weak self] in self?.pointer ?? .zero }
            arbiter.isWindowKey = { [weak self] in self?.isKey ?? false }
            arbiter.isMouseDown = { [weak self] in self?.isMouseDown ?? false }
            sidebar.cursor = .resizeLeftRight
            detail.cursor = .resizeLeft
            window.contentView?.addSubview(sidebar)
            window.contentView?.addSubview(detail)
        }

        var arbiter: WindowCursorArbiter { WindowCursorArbiter.arbiter(for: window) }

        func becomeKey() {
            isKey = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        }

        func resignKey() {
            isKey = false
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        }

        func close() {
            window.contentView = nil
        }
    }

    private var windows: [MainWindow] = []

    private func mainWindow(key: Bool = true) -> MainWindow {
        let main = MainWindow()
        main.isKey = key
        windows.append(main)
        drain()
        return main
    }

    override func setUp() async throws {
        NSCursor.arrow.set()
    }

    override func tearDown() async throws {
        for main in windows { main.close() }
        windows = []
        drain()
        NSCursor.arrow.set()
    }

    /// Runs the main queue: the arbiter decides after the current event.
    private func drain(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private var lastFollowUp: TimeInterval { WindowCursorArbiter.keyFollowUps.last ?? 0 }

    private func moveEvent() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0))
    }

    func testRegionsTakeNoHitsAndTrackThePointerInTheKeyWindow() throws {
        let main = mainWindow()
        XCTAssertNil(main.sidebar.hitTest(NSPoint(x: 304, y: 300)))
        main.sidebar.updateTrackingAreas()
        main.sidebar.updateTrackingAreas()
        let areas = main.sidebar.trackingAreas.filter { $0.owner === main.sidebar }
        XCTAssertEqual(areas.count, 1, "not added twice")
        XCTAssertTrue(areas[0].options.isSuperset(of: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow]))
    }

    /// Entering by one pixel: the cursor on the first event, and again when the hosting view puts the arrow back.
    func testOnePixelIntoTheDividerShowsTheResizeCursor() throws {
        let main = mainWindow()
        var highlighted: [Bool] = []
        main.sidebar.onPointerOver = { highlighted.append($0) }
        main.pointer = NSPoint(x: 299.5, y: 300)
        main.sidebar.mouseMoved(with: try moveEvent())
        drain()
        XCTAssertEqual(NSCursor.current, .arrow, "one pixel before the divider")
        main.pointer = NSPoint(x: 300.5, y: 300)
        main.sidebar.mouseEntered(with: try moveEvent())
        drain()
        XCTAssertEqual(NSCursor.current, .resizeLeftRight)
        XCTAssertEqual(highlighted, [true])

        NSCursor.arrow.set()  // the hosting view's cursor update
        let update = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .cursorUpdate, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil))
        WindowCursorArbiter.handle(update, in: main.window)
        drain()
        XCTAssertEqual(NSCursor.current, .resizeLeftRight)
    }

    /// Stopping right after a fast approach: an arrow set later in the same event loses to the decision after it.
    func testAFastApproachThatStopsOnTheDividerKeepsTheResizeCursor() throws {
        let main = mainWindow()
        main.pointer = NSPoint(x: 1004, y: 120)
        main.detail.mouseEntered(with: try moveEvent())
        NSCursor.arrow.set()  // SwiftUI handling the same event after the tracking area
        drain()
        XCTAssertEqual(NSCursor.current, .resizeLeft)
    }

    /// Two main windows: the window that becomes key sets the cursor under a still pointer, both ways.
    func testSwitchingBetweenTwoMainWindowsFollowsThePointer() {
        let a = mainWindow()
        let b = mainWindow(key: false)
        a.pointer = NSPoint(x: 600, y: 300)
        b.pointer = NSPoint(x: 304, y: 300)
        drain()
        XCTAssertEqual(NSCursor.current, .arrow)

        a.resignKey()
        b.becomeKey()
        drain()
        XCTAssertEqual(NSCursor.current, .resizeLeftRight, "A to B with the pointer on B's divider")
        XCTAssertTrue(b.sidebar.isPointerOver)
        XCTAssertFalse(a.sidebar.isPointerOver)

        b.resignKey()
        a.becomeKey()
        drain()
        XCTAssertEqual(NSCursor.current, .arrow, "B to A with the pointer on A's graph: B's cursor does not stay")
        XCTAssertFalse(b.sidebar.isPointerOver, "no highlight in a window that is not key")

        a.pointer = NSPoint(x: 1004, y: 300)
        a.resignKey()
        b.becomeKey()
        drain()
        b.resignKey()
        a.becomeKey()
        drain()
        XCTAssertEqual(NSCursor.current, .resizeLeft, "B to A with the pointer on A's divider")
        drain(lastFollowUp + 0.1)
    }

    /// A newly opened window becoming key: SwiftUI's arrow about half a second later is replaced again.
    func testANewWindowKeepsTheResizeCursorAfterSwiftUIsLateArrow() {
        let a = mainWindow()
        let b = mainWindow(key: false)
        b.pointer = NSPoint(x: 304, y: 300)
        a.resignKey()
        b.becomeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSCursor.arrow.set() }
        drain(lastFollowUp + 0.2)
        XCTAssertEqual(NSCursor.current, .resizeLeftRight)
    }

    /// Settings opened over the divider, the pointer moved onto the graph, Settings closed: the arrow, also when the
    /// resize cursor was still showing.
    func testClosingSettingsLeavesNoResizeCursorOverTheGraph() throws {
        let main = mainWindow()
        main.pointer = NSPoint(x: 1004, y: 300)
        main.detail.mouseEntered(with: try moveEvent())
        drain()
        XCTAssertEqual(NSCursor.current, .resizeLeft)

        main.resignKey()
        drain()
        XCTAssertFalse(main.detail.isPointerOver, "no highlight while Settings is key")
        main.pointer = NSPoint(x: 600, y: 300)
        main.becomeKey()
        drain(lastFollowUp + 0.1)
        XCTAssertEqual(NSCursor.current, .arrow)
        XCTAssertFalse(main.detail.isPointerOver)
    }

    /// Collapsing a panel by dragging: the drag keeps its cursor while the button is down; once the divider is removed
    /// (its drag never reports an end), the pointer over the graph gets the arrow.
    func testCollapsingAPanelByDraggingLeavesNoResizeCursor() {
        let main = mainWindow()
        main.pointer = NSPoint(x: 1004, y: 300)
        main.arbiter.evaluate()
        main.detail.isDragging = true
        main.isMouseDown = true
        main.pointer = NSPoint(x: 1200, y: 300)
        main.arbiter.evaluate()
        XCTAssertEqual(NSCursor.current, .resizeLeft, "a drag keeps its cursor off the gutter")

        main.isMouseDown = false
        main.detail.removeFromSuperview()
        main.pointer = NSPoint(x: 1200, y: 300)
        drain()
        XCTAssertEqual(NSCursor.current, .arrow)

        // A collapse that leaves the divider in place but its drag flag stale: the button is up, so no drag.
        let other = mainWindow()
        other.sidebar.isDragging = true
        other.isMouseDown = true
        other.pointer = NSPoint(x: 304, y: 300)
        other.arbiter.evaluate()
        other.isMouseDown = false
        other.pointer = NSPoint(x: 100, y: 300)
        let up = try? XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0))
        WindowCursorArbiter.handle(up!, in: other.window)
        drain()
        XCTAssertEqual(NSCursor.current, .arrow)
    }

    /// Releasing a drag with the pointer still on the divider keeps the resize cursor (#648), the one-way one at a
    /// limit.
    func testReleasingADragOnTheDividerKeepsTheResizeCursor() {
        let main = mainWindow()
        main.sidebar.isDragging = true
        main.isMouseDown = true
        main.pointer = NSPoint(x: 304, y: 300)
        main.arbiter.evaluate()
        main.sidebar.cursor = .resizeRight
        main.sidebar.isDragging = false
        main.isMouseDown = false
        main.arbiter.scheduleEvaluation()
        drain()
        XCTAssertEqual(NSCursor.current, .resizeRight)
        XCTAssertTrue(main.sidebar.isPointerOver)
    }

    /// Leaving a divider shows the arrow only while its cursor is still showing: another view's cursor set on the way
    /// out (a text view's I-beam) is left alone.
    func testLeavingADividerLeavesAnotherViewsCursorAlone() throws {
        let main = mainWindow()
        main.pointer = NSPoint(x: 304, y: 300)
        main.sidebar.mouseEntered(with: try moveEvent())
        drain()
        main.pointer = NSPoint(x: 320, y: 300)
        NSCursor.iBeam.set()
        main.sidebar.mouseExited(with: try moveEvent())
        drain()
        XCTAssertEqual(NSCursor.current, .iBeam)

        main.pointer = NSPoint(x: 304, y: 300)
        main.sidebar.mouseEntered(with: try moveEvent())
        drain()
        main.pointer = NSPoint(x: 320, y: 300)
        main.sidebar.mouseExited(with: try moveEvent())
        drain()
        XCTAssertEqual(NSCursor.current, .arrow)
    }
}
