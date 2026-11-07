import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// S-02 rendered offscreen in light and dark (#66). Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class WipDetailRenderTests: XCTestCase {
    private static let size = CGSize(width: 344, height: 520)

    /// The mockup's agent worktree: a conflict, an `MM` file, a rename, and an untracked note.
    private var model: WipDetailModel {
        func change(_ path: String, _ status: FileChange.Status, from: String? = nil) -> FileChange {
            FileChange(path: GitPath(path), originalPath: from.map(GitPath.init), status: status)
        }
        let state = WorkingState(
            headCommit: ObjectID("b2e8a44000000000000000000000000000000000"), head: .branch("agent/refactor-logging"),
            upstream: .none, stashCount: 0,
            staged: [
                change("internal/log/logger.go", .modified), change("internal/log/requestid.go", .added),
                change("internal/log/encoder.go", .renamed(score: 92), from: "internal/log/format.go"),
            ],
            unstaged: [change("internal/log/logger.go", .modified), change("cmd/api/main.go", .modified)],
            untracked: [change("notes/agent-plan.md", .untracked)],
            conflicted: [change("internal/http/middleware.go", .conflicted(.bothModified))],
            isPartial: false, skippedRecords: 0)
        func stat(_ path: String, _ added: Int?, _ deleted: Int?) -> FileStat {
            FileStat(path: GitPath(path), added: added, deleted: deleted)
        }
        // Line counts (#230), as in the S-02 mockup.
        let counts = WorkingLineCounts(
            staged: [
                stat("internal/log/logger.go", 40, 8), stat("internal/log/requestid.go", 12, 0),
                stat("internal/log/encoder.go", 2, 4),
            ],
            unstaged: [stat("internal/log/logger.go", 9, 1), stat("cmd/api/main.go", 2, 2)],
            isPartial: false)
        return WipDetailModel(
            entry: WorktreeListing.entry(
                "/tmp/dev/api-wt/agent-logging", branch: "agent/refactor-logging", state: .loaded(state)),
            lineCounts: .loaded(counts), home: "/tmp/dev")
    }

    private func render(_ view: some View, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let host = NSHostingView(
            rootView: view.frame(width: Self.size.width, height: Self.size.height).background(
                Tokens.Color.surfacePanel))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func color(_ name: String, in appearance: NSAppearance) throws -> NSColor {
        let named = try XCTUnwrap(NSColor(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = named.usingColorSpace(.sRGB) }
        return try XCTUnwrap(resolved)
    }

    func testRendersInLightAndDark() throws {
        let model = model
        XCTAssertEqual(model.groups.map(\.group), [.conflicted, .staged, .unstaged, .untracked])
        XCTAssertEqual(model.lineTotals, WipLineTotals(added: 65, deleted: 15))
        let view = WipDetailView(
            model: model,
            selectedFile: FileSelection(
                worktree: model.worktreePath, group: .staged, path: GitPath("internal/log/logger.go")),
            onSelect: { _ in })

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let bitmap = try render(view, appearance: appearance)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)

            // The bottom of the panel, below the cards, is the panel colour.
            let scale = CGFloat(bitmap.pixelsWide) / Self.size.width
            let bottom = try XCTUnwrap(
                bitmap.colorAt(x: Int(Self.size.width / 2 * scale), y: Int((Self.size.height - 4) * scale))?
                    .usingColorSpace(.sRGB))
            let panel = try color("Tokens/surfacePanel", in: appearance)
            XCTAssertEqual(bottom.redComponent, panel.redComponent, accuracy: 0.03, "\(name) panel")

            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("wip-detail-\(name).png"))
            }
        }
    }

    func testStatesRender() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        for state in [WorktreeListing.State.missing, .loaded(WorktreeListing.state(branch: "main"))] {
            let model = WipDetailModel(
                entry: WorktreeListing.entry("/tmp/dev/x", branch: "x", state: state), home: "/tmp/dev")
            let bitmap = try render(
                WipDetailView(model: model, selectedFile: nil, onSelect: { _ in }), appearance: appearance)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        }
    }
}
