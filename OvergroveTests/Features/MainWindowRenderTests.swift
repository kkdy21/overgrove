import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// The S-01 main window shell rendered offscreen (#64).
@MainActor
final class MainWindowRenderTests: XCTestCase {
    private var suiteName: String!
    private var store: PanelLayoutStore!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        store = PanelLayoutStore(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    /// Write operations (ADR-0011). None may appear as a toolbar action, not even disabled.
    private static let forbiddenActions = ["Pull", "Push", "Commit", "Branch", "Stash", "Checkout", "Merge", "Rebase"]
    /// For descriptive text (help, tooltips), only the verbs: "base branch" is a fine noun there.
    private static let forbiddenVerbs = forbiddenActions.filter { $0 != "Branch" }

    /// ADR-0011 / screens.md S-01: exactly Fetch, Refresh │ Compare │ Terminal, Finder; no write action.
    func testToolbarActionsAreReadOnly() {
        XCTAssertEqual(ToolbarAction.allCases.map(\.title), ["Fetch", "Refresh", "Compare", "Terminal", "Finder"])
        XCTAssertEqual(ToolbarAction.allCases.map(\.group), [.sync, .sync, .compare, .open, .open])
        for action in ToolbarAction.allCases {
            for word in Self.forbiddenActions {
                XCTAssertFalse(action.title.localizedCaseInsensitiveContains(word), "\(action.title)")
            }
            for word in Self.forbiddenVerbs {
                XCTAssertFalse(action.help.localizedCaseInsensitiveContains(word), "\(action.help)")
            }
        }
    }

    private func snapshotDirectory() -> URL? {
        ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func color(_ name: String, in appearance: NSAppearance) throws -> NSColor {
        let named = try XCTUnwrap(NSColor(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = named.usingColorSpace(.sRGB) }
        return try XCTUnwrap(resolved)
    }

    /// The window content (panels and status bar) in light and dark, with the mockup's data. The status bar row is
    /// drawn on `surface.window`. Set `OVERGROVE_SNAPSHOT_DIR` (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`)
    /// to keep the PNGs.
    func testContentRendersInLightAndDark() throws {
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let host = NSHostingView(rootView: MainWindowView(state: .mockup(layoutStore: store)))
            host.appearance = appearance
            host.frame = NSRect(x: 0, y: 0, width: 1440, height: 848)
            host.layoutSubtreeIfNeeded()
            let bitmap = try render(host)

            // A point in the status bar, between fields at the far right of the leading group.
            let statusBar = try XCTUnwrap(
                bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 4)?.usingColorSpace(.sRGB))
            let window = try color("Tokens/surfaceWindow", in: appearance)
            XCTAssertEqual(statusBar.redComponent, window.redComponent, accuracy: 0.03, "\(name) status bar")
            XCTAssertEqual(statusBar.blueComponent, window.blueComponent, accuracy: 0.03, "\(name) status bar")

            if let directory = snapshotDirectory(), let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("main-window-content-\(name).png"))
            }
        }
    }

    /// The whole window, toolbar included, as the app shows it: the SwiftUI toolbar is bridged into a real
    /// `NSToolbar`, and none of its items is a write action.
    func testWindowHasTheToolbarAndRendersInLightAndDark() throws {
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let controller = NSHostingController(rootView: MainWindowView(state: .mockup(layoutStore: store)))
            controller.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: appearanceName)
            window.setContentSize(NSSize(width: 1440, height: 900))
            defer { window.close() }
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()

            let toolbar = try XCTUnwrap(window.toolbar, "the SwiftUI toolbar is bridged into the window")
            XCTAssertFalse(toolbar.items.isEmpty)
            let labels = toolbar.items.flatMap { [$0.label, $0.paletteLabel] }
            let tooltips = toolbar.items.compactMap(\.toolTip)
            for word in Self.forbiddenActions {
                XCTAssertFalse(labels.contains { $0.localizedCaseInsensitiveContains(word) }, "\(name): \(word)")
            }
            for word in Self.forbiddenVerbs {
                XCTAssertFalse(tooltips.contains { $0.localizedCaseInsensitiveContains(word) }, "\(name): \(word)")
            }

            let frame = try XCTUnwrap(window.contentView?.superview, "window frame view")
            let bitmap = try render(frame)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = snapshotDirectory(), let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("main-window-\(name).png"))
            }
        }
    }
}
