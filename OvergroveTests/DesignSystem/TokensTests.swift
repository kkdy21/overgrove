import AppKit
import XCTest

@testable import Overgrove

/// Checks the generated design tokens against `design/tokens/tokens.json` (docs/design/design-tokens.md §4).
///
/// The JSON is resolved here independently of `scripts/tokens/generate.swift`. Every color set's four variants are
/// read from the committed `Contents.json`, and the light and dark variants are also read back from the compiled
/// catalog in the app bundle, so a generator bug, a stale commit, or a hand edit all fail.
///
/// `NSAppearance(named:)` maps the High Contrast names back to Aqua / Dark Aqua, so High Contrast cannot be resolved
/// in-process; those variants are checked in the catalog source (`assetutil --info` shows them compiled as
/// `NSAppearanceNameAccessibilitySystem` / `NSAppearanceNameAccessibilityDarkAqua`).
@MainActor
final class TokensTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let extensionKey = "io.github.kkdy21.overgrove"

    private enum Mode: String, CaseIterable {
        case light
        case dark
        case highContrast = "high-contrast"
        case darkHighContrast = "dark-high-contrast"

        var fallback: [String] {
            switch self {
            case .light: []
            case .dark: ["dark"]
            case .highContrast: ["high-contrast"]
            case .darkHighContrast: ["dark-high-contrast", "dark"]
            }
        }

        /// Appearances that can be resolved in-process (see the type comment).
        var runtimeAppearance: NSAppearance? {
            switch self {
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            case .highContrast, .darkHighContrast: nil
            }
        }

        /// The `appearances` list of this variant in a color set's `Contents.json`.
        var catalogAppearances: Set<String> {
            switch self {
            case .light: []
            case .dark: ["luminosity=dark"]
            case .highContrast: ["contrast=high"]
            case .darkHighContrast: ["luminosity=dark", "contrast=high"]
            }
        }
    }

    private struct RGBA: Equatable, CustomStringConvertible {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        var description: String {
            String(format: "rgba(%.0f %.0f %.0f %.3f)", red * 255, green * 255, blue * 255, alpha)
        }

        func isClose(to other: RGBA) -> Bool {
            let tolerance = 0.6 / 255
            return abs(red - other.red) <= tolerance && abs(green - other.green) <= tolerance
                && abs(blue - other.blue) <= tolerance && abs(alpha - other.alpha) <= tolerance
        }

        var luminance: Double {
            func linear(_ channel: Double) -> Double {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        func contrast(with other: RGBA) -> Double {
            let (high, low) = (max(luminance, other.luminance), min(luminance, other.luminance))
            return (high + 0.05) / (low + 0.05)
        }
    }

    private var cachedRoot: [String: Any]?

    private func tokensRoot() throws -> [String: Any] {
        if let cachedRoot { return cachedRoot }
        let data = try Data(contentsOf: Self.repo.appendingPathComponent("design/tokens/tokens.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        cachedRoot = root
        return root
    }

    // MARK: - Token resolution (independent of the generator)

    private func node(_ path: String) throws -> [String: Any] {
        var current: Any = try tokensRoot()
        for key in path.split(separator: ".") {
            current = try XCTUnwrap((current as? [String: Any])?[String(key)], "missing \(path)")
        }
        return try XCTUnwrap(current as? [String: Any], path)
    }

    private func color(_ path: String, _ mode: Mode) throws -> RGBA {
        let token = try node(path)
        let ext = (token["$extensions"] as? [String: Any])?[Self.extensionKey] as? [String: Any]
        let modes = ext?["modes"] as? [String: Any] ?? [:]
        let raw = mode.fallback.lazy.compactMap { modes[$0] }.first ?? token["$value"]
        let value = try XCTUnwrap(raw as? String, path)
        if value.hasPrefix("{") { return try color(String(value.dropFirst().dropLast()), mode) }
        let digits = Array(value.dropFirst())
        func byte(_ index: Int) throws -> Double {
            Double(try XCTUnwrap(Int(String(digits[index..<index + 2]), radix: 16), value)) / 255
        }
        return RGBA(
            red: try byte(0),
            green: try byte(2),
            blue: try byte(4),
            alpha: digits.count == 8 ? try byte(6) : 1
        )
    }

    /// Leaf token paths under `group`, relative to it.
    private func leaves(_ group: String) throws -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        func walk(_ node: [String: Any], _ prefix: String) {
            if node["$value"] != nil {
                result[prefix] = node
                return
            }
            for (key, child) in node where !key.hasPrefix("$") {
                if let child = child as? [String: Any] { walk(child, prefix.isEmpty ? key : "\(prefix).\(key)") }
            }
        }
        walk(try node(group), "")
        return result
    }

    private func camelCase(_ path: String) -> String {
        let words = path.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init)
        return (words.first ?? "") + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// Semantic colors that become color sets: everything except the accent, its aliases, and `border.focus`.
    private func assetColorPaths() throws -> [String] {
        try leaves("semantic.color").compactMap { path, token in
            guard let value = token["$value"] as? String else { return nil }  // numeric opacities
            if path == "accent" || path == "border.focus" || value == "{semantic.color.accent}" { return nil }
            return path
        }.sorted()
    }

    /// A variant from the committed color set source.
    private func asset(_ name: String, _ mode: Mode) throws -> RGBA {
        let url = Self.repo.appendingPathComponent("Overgrove/Resources/Assets.xcassets/\(name).colorset/Contents.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], name)
        let entries = try XCTUnwrap(json["colors"] as? [[String: Any]], name)
        let entry = try XCTUnwrap(
            entries.first { entry in
                let list = entry["appearances"] as? [[String: String]] ?? []
                return Set(list.map { "\($0["appearance"] ?? "")=\($0["value"] ?? "")" }) == mode.catalogAppearances
            },
            "\(name) has no \(mode.rawValue) variant"
        )
        let color = try XCTUnwrap(entry["color"] as? [String: Any], name)
        XCTAssertEqual(color["color-space"] as? String, "srgb", name)
        let components = try XCTUnwrap(color["components"] as? [String: String], name)
        func channel(_ key: String) throws -> Double {
            let text = try XCTUnwrap(components[key], "\(name).\(key)")
            return Double(try XCTUnwrap(Int(text.dropFirst(2), radix: 16), "\(name).\(key)")) / 255
        }
        return RGBA(
            red: try channel("red"),
            green: try channel("green"),
            blue: try channel("blue"),
            alpha: try XCTUnwrap(Double(components["alpha"] ?? ""), "\(name).alpha")
        )
    }

    /// A variant resolved from the compiled catalog in the app bundle.
    private func compiled(_ name: String, _ mode: Mode) throws -> RGBA {
        let color = try XCTUnwrap(NSColor(named: name), "no color set \(name) in the app bundle")
        let appearance = try XCTUnwrap(mode.runtimeAppearance, mode.rawValue)
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        let srgb = try XCTUnwrap(resolved, name)
        return RGBA(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent),
            alpha: Double(srgb.alphaComponent)
        )
    }

    // MARK: - Colors

    func testEverySemanticColorHasAColorSetMatchingTokensInAllFourAppearances() throws {
        let paths = try assetColorPaths()
        XCTAssertGreaterThan(paths.count, 60)
        for path in paths {
            for mode in Mode.allCases {
                let expected = try color("semantic.color.\(path)", mode)
                let actual = try asset("Tokens/\(camelCase(path))", mode)
                XCTAssertTrue(actual.isClose(to: expected), "\(path) [\(mode.rawValue)]: \(actual) ≠ \(expected)")
            }
        }
    }

    func testCompiledCatalogResolvesLightAndDarkLikeTheSource() throws {
        for path in try assetColorPaths() {
            for mode in [Mode.light, .dark] {
                let name = "Tokens/\(camelCase(path))"
                let actual = try compiled(name, mode)
                let expected = try asset(name, mode)
                XCTAssertTrue(actual.isClose(to: expected), "\(path) [\(mode.rawValue)]: \(actual) ≠ \(expected)")
            }
        }
    }

    func testColorSetFolderHasExactlyTheTokenColorSets() throws {
        let folder = Self.repo.appendingPathComponent("Overgrove/Resources/Assets.xcassets/Tokens")
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
            $0.hasSuffix(".colorset")
        }
        XCTAssertEqual(Set(onDisk), Set(try assetColorPaths().map { "\(camelCase($0)).colorset" }))
    }

    func testIssue166ColorGroupsAreAllColorSets() throws {
        let names = Set(try assetColorPaths().map { $0.split(separator: ".").first.map(String.init) ?? "" })
        XCTAssertTrue(
            names.isSuperset(of: ["surface", "text", "border", "status", "on-status", "graph", "diff", "avatar"]))
        let paths = try assetColorPaths()
        XCTAssertTrue(paths.contains("surface.hover"), "alpha surfaces are color sets too")
        XCTAssertEqual(paths.filter { $0.hasPrefix("graph.lane.") }.count, 8)
        XCTAssertEqual(paths.filter { $0.hasPrefix("graph.on-lane.") }.count, 8)
        XCTAssertEqual(Tokens.Color.graphLanes.count, 8)
        XCTAssertEqual(Tokens.Color.graphOnLanes.count, 8)
        XCTAssertEqual(Tokens.Color.avatars.count, 8)
    }

    func testAccentColorAssetIsTheForestAccent() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSAccentColorName") as? String, "AccentColor")
        for mode in [Mode.light, .dark] {
            XCTAssertTrue(try compiled("AccentColor", mode).isClose(to: try asset("AccentColor", mode)))
        }
        for mode in Mode.allCases {
            let actual = try asset("AccentColor", mode)
            let expected = try color("semantic.color.accent", mode)
            XCTAssertTrue(actual.isClose(to: expected), "accent [\(mode.rawValue)]: \(actual) ≠ \(expected)")
        }
        XCTAssertEqual(try color("semantic.color.accent", .light), try color("primitive.color.forest.700", .light))
        XCTAssertEqual(try color("semantic.color.accent", .dark), try color("primitive.color.forest.400", .light))
    }

    func testIncreaseContrastSwapsBorderAndTertiaryText() throws {
        for (mode, base) in [(Mode.highContrast, Mode.light), (.darkHighContrast, .dark)] {
            XCTAssertEqual(try asset("Tokens/borderPanel", mode), try asset("Tokens/borderStrong", base))
            XCTAssertEqual(try asset("Tokens/textTertiary", mode), try asset("Tokens/textSecondary", base))
        }
    }

    /// The same rule as `colorcheck.py` for the Increase Contrast modes, measured on the committed color sets.
    func testIncreaseContrastStatusAndLaneColorsReach4_5OnEveryPanelSurface() throws {
        let surfaces = ["surfaceCanvas", "surfacePanel", "surfacePanelHeader", "surfaceRaised", "surfaceSelection"]
        let foregrounds =
            ["statusStaged", "statusUnstaged", "statusUntracked", "statusConflicted", "statusAhead", "statusBehind"]
            + ["statusLocked", "statusPrunable", "statusOk", "statusWarning", "statusError"]
            + (0..<8).map { "graphLane\($0)" }
        for mode in [Mode.highContrast, .darkHighContrast] {
            for foreground in foregrounds {
                let color = try asset("Tokens/\(foreground)", mode)
                for surface in surfaces {
                    let ratio = color.contrast(with: try asset("Tokens/\(surface)", mode))
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(foreground) on \(surface) [\(mode.rawValue)]")
                }
            }
            for index in 0..<8 {
                let ratio = try asset("Tokens/graphOnLane\(index)", mode)
                    .contrast(with: try asset("Tokens/graphLane\(index)", mode))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "on-lane \(index) [\(mode.rawValue)]")
            }
            for status in ["Staged", "Unstaged", "Untracked", "Conflicted", "Ahead"] {
                let ratio = try asset("Tokens/onStatus\(status)", mode)
                    .contrast(with: try asset("Tokens/status\(status)", mode))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "on-status \(status) [\(mode.rawValue)]")
            }
        }
    }

    // MARK: - Constants

    private func pixels(_ path: String) throws -> Double {
        let text = try XCTUnwrap(try node(path)["$value"] as? String, path)
        return try XCTUnwrap(Double(text.replacingOccurrences(of: "px", with: "")), path)
    }

    private func assertTable(
        _ group: String,
        _ table: [String: Double],
        excluding: Set<String> = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let paths = Set(try leaves("semantic.\(group)").keys).subtracting(excluding)
        XCTAssertEqual(Set(table.keys), paths, "every \(group) token has a constant", file: file, line: line)
        for (path, actual) in table {
            let token = try node("semantic.\(group).\(path)")
            let expected: Double =
                switch token["$value"] {
                case let number as Double: number
                case let text as String where text.hasSuffix("ms"): (Double(text.dropLast(2)) ?? .nan) / 1000
                default: try pixels("semantic.\(group).\(path)")
                }
            XCTAssertEqual(actual, expected, accuracy: 1e-9, "\(group).\(path)", file: file, line: line)
        }
    }

    func testSpacingAndRadiusMatchTokens() throws {
        try assertTable(
            "spacing",
            [
                "xxs": Tokens.Spacing.xxs, "xs": Tokens.Spacing.xs, "sm": Tokens.Spacing.sm, "md": Tokens.Spacing.md,
                "lg": Tokens.Spacing.lg, "xl": Tokens.Spacing.xl, "xxl": Tokens.Spacing.xxl,
            ]
        )
        try assertTable(
            "radius",
            ["sm": Tokens.Radius.sm, "md": Tokens.Radius.md, "lg": Tokens.Radius.lg, "pill": Tokens.Radius.pill]
        )
    }

    func testSizesMatchTokens() throws {
        typealias S = Tokens.Size
        let table: [String: Double] = [
            "row-sidebar": S.rowSidebar, "row-worktree": S.rowWorktree, "row-graph": S.rowGraph, "row-file": S.rowFile,
            "graph-lane-width": S.graphLaneWidth, "graph-node": S.graphNode, "graph-node-merge": S.graphNodeMerge,
            "graph-node-head": S.graphNodeHead, "graph-edge": S.graphEdge, "graph-node-ring": S.graphNodeRing,
            "graph-max-lanes-visible": Double(S.graphMaxLanesVisible), "ref-pill-height": S.refPillHeight,
            "ref-pill-max-width": S.refPillMaxWidth, "symbol-small": S.symbolSmall, "symbol-medium": S.symbolMedium,
            "hit-target-min": S.hitTargetMin, "panel-gap": S.panelGap, "panel-header": S.panelHeader,
            "status-bar": S.statusBar,
            "column-header": S.columnHeader, "sidebar-width-min": S.sidebarWidthMin,
            "sidebar-width-ideal": S.sidebarWidthIdeal, "sidebar-width-max": S.sidebarWidthMax,
            "detail-width-min": S.detailWidthMin, "detail-width-ideal": S.detailWidthIdeal,
            "detail-width-max": S.detailWidthMax, "graph-width-min": S.graphWidthMin,
            "column-refs-ideal": S.columnRefsIdeal, "column-author-ideal": S.columnAuthorIdeal,
            "column-date-ideal": S.columnDateIdeal, "column-sha-ideal": S.columnShaIdeal,
            "window-min-width": S.windowMinWidth, "window-min-height": S.windowMinHeight,
        ]
        let sized = try leaves("semantic.size").keys.filter { $0 != "splitter-grip" }
        XCTAssertEqual(Set(table.keys), Set(sized))
        for (path, actual) in table {
            let token = try node("semantic.size.\(path)")
            let expected = try (token["$value"] as? Double) ?? pixels("semantic.size.\(path)")
            XCTAssertEqual(actual, expected, path)
        }
        XCTAssertEqual(S.splitterGrip, CGSize(width: 4, height: 28))
        XCTAssertEqual(try node("semantic.size.splitter-grip")["$value"] as? String, "4px × 28px")
    }

    func testMotionOpacityAndTypographyMatchTokens() throws {
        try assertTable(
            "motion",
            [
                "duration-fast": Tokens.Motion.durationFast, "duration-standard": Tokens.Motion.durationStandard,
                "duration-slow": Tokens.Motion.durationSlow,
            ],
            excluding: ["easing-standard"]
        )
        let curve = Tokens.Motion.easingStandardControlPoints
        XCTAssertEqual(
            try node("semantic.motion.easing-standard")["$value"] as? [Double],
            [curve.x1, curve.y1, curve.x2, curve.y2]
        )
        try assertTable("opacity", ["disabled": Tokens.Opacity.disabled, "stale": Tokens.Opacity.stale])
        let graph = try leaves("semantic.color.graph").compactMapValues { $0["$value"] as? Double }
        XCTAssertEqual(
            graph,
            [
                "ref-pill-local-fill-opacity": Tokens.Graph.refPillLocalFillOpacity,
                "ref-pill-border-opacity": Tokens.Graph.refPillBorderOpacity,
                "ref-connector-opacity": Tokens.Graph.refConnectorOpacity,
                "selection-opacity": Tokens.Graph.selectionOpacity,
            ]
        )
        XCTAssertEqual(Tokens.Font.sectionHeaderTracking, 0.66, accuracy: 1e-9, "0.06em at 11px")
    }

    func testEveryTypographyTokenMapsToASwiftUIFont() throws {
        for (path, token) in try leaves("semantic.typography") {
            let ext = (token["$extensions"] as? [String: Any])?[Self.extensionKey] as? [String: Any]
            let mapping = try XCTUnwrap(ext?["swiftui"] as? String, "\(path) has no swiftui mapping")
            XCTAssertTrue(mapping.hasPrefix("Font."), path)
        }
    }
}
