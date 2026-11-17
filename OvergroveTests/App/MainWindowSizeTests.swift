import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// The first main window's size and the window's minimum height (#685, art-direction.md §3).
@MainActor
final class MainWindowSizeTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testTheFirstWindowOpensAtTheReferenceSize() {
        XCTAssertEqual(MainWindowSize.standard, CGSize(width: 1440, height: 900))
        XCTAssertEqual(MainWindowSize.initial(visibleScreen: nil), MainWindowSize.standard)
        // The VM of #685: a 1680×1050 screen.
        XCTAssertEqual(
            MainWindowSize.initial(visibleScreen: CGSize(width: 1680, height: 1001)), MainWindowSize.standard)
    }

    func testASmallerScreenLimitsTheFirstWindow() {
        XCTAssertEqual(
            MainWindowSize.initial(visibleScreen: CGSize(width: 1280, height: 775)),
            CGSize(width: 1280, height: 775))
        XCTAssertEqual(
            MainWindowSize.initial(visibleScreen: CGSize(width: 1920, height: 820)),
            CGSize(width: 1440, height: 820), "only the dimension that does not fit")
    }

    /// The window cannot be made shorter than `size.window-min-height` below the toolbar. Before #685 it had no
    /// minimum height and opened at its content's ideal height, 450pt.
    func testTheMainWindowHasTheMinimumHeight() {
        let controller = NSHostingController(
            rootView: MainWindowView(state: .mockup(layoutStore: PanelLayoutStore(defaults: defaults))))
        let smallest = controller.sizeThatFits(in: CGSize(width: Tokens.Size.windowMinWidth, height: 0))
        XCTAssertEqual(smallest.height, Tokens.Size.windowMinHeight, accuracy: 0.5)
    }

    /// The setup assistant of the first run (#685: no repository, git ready, GitHub CLI not logged in) fits the
    /// shortest main window, so its sheet never hangs below the window, also at the first window's size.
    func testTheFirstRunSetupAssistantFitsTheWindow() async {
        let setup = SetupAssistantState(
            gitChecker: StubGitSetupChecker(
                .ready(version: GitVersion(major: 2, minor: 50, patch: 1), path: "/usr/bin/git")),
            ghChecker: StubGHAuthChecker(.notLoggedIn))
        setup.present()
        await setup.gitTask?.value
        await setup.gitHubTask?.value
        let controller = NSHostingController(
            rootView: SetupAssistantView(
                setup: setup, repositoryPath: nil, isAddingRepository: false, onChooseFolder: {}))
        let sheet = controller.sizeThatFits(in: CGSize(width: SetupAssistantView.width, height: .infinity))
        XCTAssertGreaterThan(sheet.height, 0)
        XCTAssertLessThanOrEqual(sheet.height, Tokens.Size.windowMinHeight)
        XCTAssertLessThanOrEqual(sheet.width, Tokens.Size.windowMinWidth)
    }
}
