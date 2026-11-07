import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// Chip and control outlines and graph ref marks under Increase Contrast (#304, interaction.md §6.4).
@MainActor
final class ContrastOutlineTests: XCTestCase {
    func testStandardContrastKeepsTodaysOutlines() {
        XCTAssertEqual(
            Tokens.controlOutline(.standard, normal: Tokens.Color.borderSeparator),
            Tokens.ControlOutline(color: Tokens.Color.borderSeparator, width: 1))
        XCTAssertNil(Tokens.controlOutline(.standard, normal: nil), "no outline today: none in standard contrast")
        XCTAssertEqual(
            Tokens.controlOutline(.standard, normal: Tokens.Color.textSecondary, increased: Tokens.Color.textSecondary),
            Tokens.ControlOutline(color: Tokens.Color.textSecondary, width: 1))
    }

    func testIncreaseContrastUsesBorderStrongAtOneAndAHalfPoints() {
        for normal in [Tokens.Color.borderSeparator, nil] {
            XCTAssertEqual(
                Tokens.controlOutline(.increased, normal: normal),
                Tokens.ControlOutline(color: Tokens.Color.borderStrong, width: 1.5))
        }
        XCTAssertEqual(
            Tokens.controlOutline(.increased, normal: Tokens.Color.textTertiary, increased: Tokens.Color.textTertiary),
            Tokens.ControlOutline(color: Tokens.Color.textTertiary, width: 1.5),
            "a text-coloured outline stays the stronger colour")
    }

    func testRefMarksTakeTheFullLaneColourUnderIncreaseContrast() {
        XCTAssertEqual(Tokens.refMarkOpacity(.standard, normal: Tokens.Graph.refPillBorderOpacity), 0.75)
        XCTAssertEqual(Tokens.refMarkOpacity(.standard, normal: Tokens.Graph.refConnectorOpacity), 0.55)
        XCTAssertEqual(Tokens.refMarkOpacity(.increased, normal: Tokens.Graph.refPillBorderOpacity), 1)
        XCTAssertEqual(Tokens.refMarkOpacity(.increased, normal: Tokens.Graph.refConnectorOpacity), 1)
    }

    // MARK: Rendering

    /// The outline modifier draws nothing extra in standard contrast and a border under Increase Contrast.
    func testOutlineModifierDrawsOnlyUnderIncreaseContrast() throws {
        let chip = Text("Filter").padding(8).controlOutline(Capsule(), normal: nil)
        let size = CGSize(width: 120, height: 40)
        let plain = try render(Text("Filter").padding(8), size: size, contrast: .standard)
        let standard = try render(chip, size: size, contrast: .standard)
        let increased = try render(chip, size: size, contrast: .increased)
        XCTAssertEqual(standard, plain, "standard contrast: no change on screen")
        XCTAssertNotEqual(increased, plain, "Increase Contrast: an outline appears")
    }

    /// The chips and controls #304 lists, side by side, in light and dark under both contrasts. Set
    /// `OVERGROVE_SNAPSHOT_DIR` (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
    func testChipsAndControlsRenderUnderIncreaseContrast() throws {
        let gallery = VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            SidebarFilterField(text: .constant(""), focusRequest: 0).frame(width: 220)
            DetailSegmentPicker(isWorktree: false, onChanges: {}, onWorktree: {})
            HStack(spacing: Tokens.Spacing.sm) {
                Text("main worktree").font(Tokens.Font.pill).padding(.horizontal, Tokens.Spacing.xs)
                    .controlOutline(Capsule())
                IssueNumberBadge(number: 42)
                AIBadge()
            }
            HStack(spacing: Tokens.Spacing.sm) {
                ForEach(Array(Self.pills.enumerated()), id: \.offset) { index, pill in
                    GraphRefPillView(pill: pill, laneColor: Tokens.Color.graphLanes[index + 1], laneIndex: index + 1)
                }
            }
        }
        .padding(Tokens.Spacing.md)
        .background(Tokens.Color.surfacePanel)
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                let png = try render(
                    gallery, size: CGSize(width: 360, height: 170), contrast: contrast, appearance: appearance,
                    asPNG: true)
                if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"] {
                    let name = "contrast-controls-\(mode)-\(contrast == .increased ? "increased" : "standard").png"
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
            XCTAssertNotEqual(
                try render(gallery, size: CGSize(width: 360, height: 170), contrast: .standard, appearance: appearance),
                try render(
                    gallery, size: CGSize(width: 360, height: 170), contrast: .increased, appearance: appearance),
                "\(mode): Increase Contrast changes the outlines")
        }
    }

    private static let pills = [
        GraphRefPill(kind: .worktreeBranch, title: "feat/42", hasMatchingRemote: false, tooltip: "refs/heads/feat/42"),
        GraphRefPill(kind: .localBranch, title: "main", hasMatchingRemote: true, tooltip: "refs/heads/main"),
        GraphRefPill(
            kind: .remoteBranch, title: "origin/fix", hasMatchingRemote: false, tooltip: "refs/remotes/origin/fix"),
    ]

    private func render(
        _ view: some View, size: CGSize, contrast: ColorSchemeContrast, appearance: NSAppearance.Name = .aqua,
        asPNG: Bool = false
    ) throws -> Data {
        let host = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height).environment(\._colorSchemeContrast, contrast))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if asPNG { return try XCTUnwrap(bitmap.representation(using: .png, properties: [:])) }
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}
