import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// S-02's Submodules card (#108) rendered offscreen in light and dark. Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class SubmoduleSectionRenderTests: XCTestCase {
    private static let size = CGSize(width: 344, height: 240)

    private var model: SubmoduleSectionModel? {
        func submodule(_ path: String, _ state: SubmoduleStatus.State, listed: Bool = true) -> SubmoduleStatus {
            SubmoduleStatus(path: GitPath(path), isListed: listed, state: state)
        }
        return SubmoduleSectionModel(
            .loaded(
                SubmoduleListing(
                    submodules: [
                        submodule("vendor/http", .clean),
                        submodule("vendor/proto", .changed(files: 3, untracked: 1, isPartial: false)),
                        submodule("third_party/legacy", .notCheckedOut),
                        submodule("libs/untrusted", .notInspected(.blocked(reason: "filter driver name not allowed"))),
                        submodule("tools/moved", .clean, listed: false),
                    ],
                    omitted: 2, isGitmodulesRefused: false)))
    }

    private func render(_ view: some View, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let host = NSHostingView(
            rootView: view.padding(Tokens.Spacing.md).frame(width: Self.size.width, height: Self.size.height)
                .background(Tokens.Color.surfacePanel))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    func testRendersInLightAndDark() throws {
        let model = try XCTUnwrap(model)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let bitmap = try render(SubmoduleSectionView(model: model), appearance: appearance)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("submodules-\(name).png"))
            }
        }
    }

    func testCheckingAndFailedRender() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        for result in [SubmodulePanel.Result.pending, .failed] {
            let model = try XCTUnwrap(SubmoduleSectionModel(result))
            XCTAssertGreaterThan(try render(SubmoduleSectionView(model: model), appearance: appearance).pixelsWide, 0)
        }
    }
}
