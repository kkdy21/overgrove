import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// S-07 rendered offscreen in light and dark (#85), in the mockup's state: a repository added, git ready, GitHub
/// CLI not logged in. Set `OVERGROVE_SNAPSHOT_DIR` (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep PNGs.
@MainActor
final class SetupAssistantRenderTests: XCTestCase {
    private static let size = CGSize(width: 640, height: 760)

    func testRendersTheMockupStateInLightAndDark() async throws {
        let setup = SetupAssistantState(
            gitChecker: StubGitSetupChecker(
                .ready(version: GitVersion(major: 2, minor: 50, patch: 1), path: "/usr/bin/git")),
            ghChecker: StubGHAuthChecker(.notLoggedIn))
        setup.checkGit()
        setup.checkGitHub()
        await setup.gitTask?.value
        await setup.gitHubTask?.value
        XCTAssertTrue(setup.canFinish(hasRepository: true))

        let view = SetupAssistantView(
            setup: setup, repositoryPath: "~/dev/api", isAddingRepository: false, onChooseFolder: {})
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(
                rootView: view.frame(width: Self.size.width, height: Self.size.height)
                    .background(Tokens.Color.surfacePanel))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(origin: .zero, size: Self.size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0, name)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("setup-assistant-\(name).png"))
            }
        }
    }

    /// #383: a supported but older git is ready, with the note on what it does not fetch.
    func testOlderGitShowsTheNote() async throws {
        let setup = SetupAssistantState(
            gitChecker: StubGitSetupChecker(
                .ready(version: GitVersion(major: 2, minor: 39, patch: 3), path: "/usr/bin/git")),
            ghChecker: StubGHAuthChecker(.notLoggedIn))
        setup.checkGit()
        await setup.gitTask?.value
        let view = SetupAssistantView(
            setup: setup, repositoryPath: "~/dev/api", isAddingRepository: false, onChooseFolder: {})
        let host = NSHostingView(rootView: view.frame(width: Self.size.width, height: Self.size.height))
        host.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
            let png = bitmap.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("setup-assistant-older-git.png"))
        }
    }
}
