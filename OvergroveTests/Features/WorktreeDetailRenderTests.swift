import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// S-05 rendered offscreen in light and dark (#67). Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class WorktreeDetailRenderTests: XCTestCase {
    private static let size = CGSize(width: 344, height: 640)

    /// The mockup's state: a tracked branch and two neutralized repository settings.
    private var model: WorktreeDetailModel {
        let now = Date()
        func entry(_ key: String) -> ConfigEntry {
            let parts = key.split(separator: ".").map(String.init)
            return ConfigEntry(
                scope: .local, section: parts[0], subsection: parts.count == 3 ? parts[1] : nil,
                variable: parts.last ?? "", value: "x")
        }
        let inspection = WorktreeInspection(
            inspection: RepoConfigInspector.inspect(
                ConfigParser.Listing(
                    entries: [entry("filter.lfs.process"), entry("core.sshcommand")], isPartial: false)),
            failure: nil, inspectedAt: now.addingTimeInterval(-60),
            gitVersion: GitVersion(major: 2, minor: 50, patch: 1),
            commonArguments: GitEnvironment.commonArguments, diffArguments: ["diff", "--no-ext-diff", "--no-textconv"],
            hookExecutables: [], realPath: nil)
        let state = WorktreeListing.state(
            branch: "fix/57-token-refresh", staged: 1, unstaged: 2,
            upstream: .tracking(upstream: "origin/fix/57-token-refresh", ahead: 1, behind: 0))
        return WorktreeDetailModel(
            entry: WorktreeListing.entry("/tmp/dev/api-wt/57", branch: "fix/57-token-refresh", state: .loaded(state)),
            inspection: inspection, fetchStatus: .idle(lastFetched: now.addingTimeInterval(-120)), now: now,
            home: "/tmp/dev")
    }

    private func render(_ view: some View, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let host = NSHostingView(
            rootView: view.frame(width: Self.size.width, height: Self.size.height).background(Tokens.Color.surfacePanel)
        )
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    func testRendersInLightAndDark() throws {
        let model = model
        XCTAssertEqual(
            model.security?.rows.filter { $0.mark == .neutralized }.map(\.title),
            [
                "Filters neutralized", "Transport commands neutralized",
            ])
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let bitmap = try render(WorktreeDetailView(model: model), appearance: appearance)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("worktree-detail-\(name).png"))
            }
        }
    }

    /// #107: a trusted repository with a remote on this Mac shows the warning and the toggle; untrusted shows the
    /// mode instead.
    func testLocalRemoteWarningAndUntrustedModeRender() throws {
        let now = Date()
        let inspection = WorktreeInspection(
            inspection: RepoConfigInspector.inspect(
                ConfigParser.Listing(
                    entries: [
                        ConfigEntry(
                            scope: .local, section: "remote", subsection: "origin", variable: "url",
                            value: "/srv/git/api.git")
                    ], isPartial: false)),
            failure: nil, inspectedAt: now.addingTimeInterval(-60),
            gitVersion: GitVersion(major: 2, minor: 50, patch: 1),
            commonArguments: GitEnvironment.commonArguments, diffArguments: ["diff", "--no-ext-diff", "--no-textconv"],
            hookExecutables: [], realPath: nil)
        let entry = WorktreeListing.entry(
            "/tmp/dev/api", branch: "main", isMain: true, state: .loaded(WorktreeListing.state(branch: "main")))
        for isUntrusted in [false, true] {
            let model = WorktreeDetailModel(
                entry: entry, inspection: inspection, fetchStatus: .never, now: now, home: "/tmp/dev",
                isUntrusted: isUntrusted)
            XCTAssertEqual(model.security?.localRemoteWarning == nil, isUntrusted)
            XCTAssertEqual(model.security?.untrustedNote == nil, !isUntrusted)
            for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                let bitmap = try render(
                    WorktreeDetailView(model: model, onSetUntrusted: { _ in }), appearance: appearance)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                    let png = bitmap.representation(using: .png, properties: [:])
                {
                    let file = "worktree-detail-\(isUntrusted ? "untrusted" : "local-remote")-\(name).png"
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
                }
            }
        }
    }

    func testSegmentAndLoadingStatesRender() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let loading = WorktreeDetailModel(
            entry: WorktreeListing.entry("/tmp/dev/x", branch: "x", state: .loaded(WorktreeListing.state(branch: "x"))),
            inspection: nil, fetchStatus: .never, now: Date())
        XCTAssertGreaterThan(try render(WorktreeDetailView(model: loading), appearance: appearance).pixelsWide, 0)
        let picker = DetailSegmentPicker(isWorktree: true, onChanges: {}, onWorktree: {})
        XCTAssertGreaterThan(try render(picker, appearance: appearance).pixelsWide, 0)
    }
}
