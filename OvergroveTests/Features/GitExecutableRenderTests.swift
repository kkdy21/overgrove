import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// Settings › Advanced and the setup assistant's refused-choice step (screens.md S-07, S-08, ADR-0019, #106), rendered
/// offscreen in light and dark. Set `OVERGROVE_SNAPSHOT_DIR` (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to
/// keep the PNGs.
@MainActor
final class GitExecutableRenderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "overgrove-git-render-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func render(_ view: some View, size: CGSize, name: String) throws {
        for (mode, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0, "\(name)-\(mode)")
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(mode).png"))
            }
        }
    }

    private func model(
        chosen: String?, resolve: @escaping @Sendable (String?) throws -> GitEnvironment, signed: Bool
    ) -> GitExecutableSettingsModel {
        let settings = AppSettings(defaults: defaults)
        settings.gitExecutablePath = chosen
        return GitExecutableSettingsModel(
            settings: settings, repositories: { [] }, resolve: { path, _ in try resolve(path) },
            isAppleSigned: { _ in signed }, resetSharedClient: {})
    }

    /// Homebrew git chosen, old enough to show the partial-clone note.
    func testAdvancedTabWithAChosenGit() async throws {
        let model = model(
            chosen: "/opt/homebrew/bin/git",
            resolve: { _ in
                GitEnvironment(
                    executable: URL(fileURLWithPath: "/opt/homebrew/Cellar/git/2.40.0/bin/git"),
                    version: GitVersion(major: 2, minor: 40, patch: 0))
            }, signed: false)
        await model.refresh()
        guard case .ready(let report) = model.state else { return XCTFail("got \(model.state)") }
        XCTAssertFalse(report.canFetchPartialClones)
        XCTAssertEqual(AdvancedSettingsView.summary(report), "git 2.40.0 · Not signed by Apple")
        try render(
            AdvancedSettingsView(model: model), size: CGSize(width: SettingsView.width, height: 260),
            name: "settings-advanced-chosen")
    }

    /// A stored choice that fails the rules: the reason and Use Default (fail closed).
    func testAdvancedTabWithARefusedChoice() async throws {
        let model = model(
            chosen: "/Users/example/repo/bin/git",
            resolve: { path in
                throw GitError.chosenExecutableRejected(
                    path: path ?? "", reason: "A git inside a registered repository cannot be used.")
            }, signed: false)
        await model.refresh()
        XCTAssertEqual(
            model.state,
            .rejected(
                path: "/Users/example/repo/bin/git", reason: "A git inside a registered repository cannot be used."))
        try render(
            AdvancedSettingsView(model: model), size: CGSize(width: SettingsView.width, height: 260),
            name: "settings-advanced-refused")
    }

    func testSetupAssistantOffersUseDefaultForARefusedChoice() async throws {
        let setup = SetupAssistantState(
            gitChecker: StubGitSetupChecker(
                .chosenRejected(
                    path: "/Users/example/repo/bin/git", reason: "A git inside a registered repository cannot be used.")
            ),
            ghChecker: StubGHAuthChecker(.notLoggedIn), useDefaultGit: {})
        setup.checkGit()
        setup.checkGitHub()
        await setup.gitTask?.value
        await setup.gitHubTask?.value
        XCTAssertFalse(setup.canFinish(hasRepository: true))
        try render(
            SetupAssistantView(setup: setup, repositoryPath: "~/dev/api", isAddingRepository: false, onChooseFolder: {})
                .background(Tokens.Color.surfacePanel),
            size: CGSize(width: 640, height: 780), name: "setup-assistant-git-refused")
    }
}
