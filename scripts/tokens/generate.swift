// Generates the app's design tokens from design/tokens/tokens.json (docs/design/design-tokens.md §4, ADR-0017).
//
//   swift scripts/tokens/generate.swift
//
// Outputs (committed; CI re-runs this script and fails on any difference):
//   Overgrove/Resources/Assets.xcassets/AccentColor.colorset   semantic.color.accent
//   Overgrove/Resources/Assets.xcassets/Tokens/*.colorset      every other semantic color, four appearances each
//   Overgrove/DesignSystem/Tokens.generated.swift              `Tokens` constants
//
// Toolchain only (Foundation, no packages; ADR-0006). The output is deterministic: keys are sorted, numbers are
// printed in their shortest form, and color sets that no longer have a token are deleted.

import Foundation

// MARK: - Errors

struct GeneratorError: Error, CustomStringConvertible {
    let description: String
}

func fail(_ message: String) -> GeneratorError { GeneratorError(description: message) }

// MARK: - Token tree

let extensionKey = "io.github.kkdy21.overgrove"

/// Appearance modes, in Asset Catalog order. Lookup falls back along `fallback`, then to `$value` (light).
enum Mode: String, CaseIterable {
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
}

struct TokenTree {
    let root: [String: Any]

    func node(_ path: String) throws -> [String: Any] {
        var current: Any = root
        for key in path.split(separator: ".") {
            guard let dict = current as? [String: Any], let next = dict[String(key)] else {
                throw fail("unknown token path: \(path)")
            }
            current = next
        }
        guard let leaf = current as? [String: Any] else { throw fail("not a group or token: \(path)") }
        return leaf
    }

    static func extensions(of token: [String: Any]) -> [String: Any] {
        (token["$extensions"] as? [String: Any])?[extensionKey] as? [String: Any] ?? [:]
    }

    /// The raw (unresolved) value of a token in a mode.
    func rawValue(_ path: String, mode: Mode) throws -> Any {
        let token = try node(path)
        let modes = Self.extensions(of: token)["modes"] as? [String: Any] ?? [:]
        for key in mode.fallback {
            if let value = modes[key] { return value }
        }
        guard let value = token["$value"] else { throw fail("token without $value: \(path)") }
        return value
    }

    /// A color resolved to `#rrggbb` or `#rrggbbaa`. Aliases resolve in the same mode.
    func color(_ path: String, mode: Mode, depth: Int = 0) throws -> String {
        guard depth < 16 else { throw fail("alias cycle at \(path)") }
        guard let value = try rawValue(path, mode: mode) as? String else {
            throw fail("color is not a string: \(path)")
        }
        if let target = Self.aliasTarget(value) { return try color(target, mode: mode, depth: depth + 1) }
        guard value.range(of: "^#([0-9a-f]{6}|[0-9a-f]{8})$", options: .regularExpression) != nil else {
            throw fail("bad color \(value) at \(path)")
        }
        return value
    }

    static func aliasTarget(_ value: String) -> String? {
        guard value.hasPrefix("{"), value.hasSuffix("}") else { return nil }
        return String(value.dropFirst().dropLast())
    }

    /// Leaf tokens under `group` as (relative path, token), sorted with numeric segments in numeric order.
    func leaves(under group: String) throws -> [(path: String, token: [String: Any])] {
        var result: [(String, [String: Any])] = []
        func walk(_ node: [String: Any], _ prefix: String) {
            if node["$value"] != nil {
                result.append((prefix, node))
                return
            }
            for (key, child) in node where !key.hasPrefix("$") {
                if let child = child as? [String: Any] { walk(child, prefix.isEmpty ? key : "\(prefix).\(key)") }
            }
        }
        walk(try node(group), "")
        return result.sorted { $0.0.compare($1.0, options: [.numeric, .literal]) == .orderedAscending }
    }
}

// MARK: - Names and numbers

/// `surface.panel-header` → `surfacePanelHeader`, `graph.lane.0` → `graphLane0`.
func camelCase(_ path: String) -> String {
    let words = path.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init)
    guard let first = words.first else { return path }
    return first + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
}

/// Shortest decimal form, rounded to 1e-6 so binary noise (0.06 × 11) does not leak into the output.
func number(_ value: Double) -> String {
    let rounded = (value * 1_000_000).rounded() / 1_000_000
    if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int(rounded)) }
    return "\(rounded)"
}

func pixels(_ text: String, at path: String) throws -> Double {
    guard text.hasSuffix("px"), let value = Double(text.dropLast(2)) else {
        throw fail("bad dimension \(text) at \(path)")
    }
    return value
}

// MARK: - Color sets

struct RGBA: Equatable {
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Int

    init(hex: String) {
        let digits = Array(hex.dropFirst())
        func byte(_ index: Int) -> Int { Int(String(digits[index..<index + 2]), radix: 16) ?? 0 }
        red = byte(0)
        green = byte(2)
        blue = byte(4)
        alpha = digits.count == 8 ? byte(6) : 255
    }
}

/// Asset Catalog JSON in Xcode's own layout, so opening the catalog in Xcode does not rewrite the files.
func colorSetJSON(_ variants: [Mode: String]) throws -> String {
    func hexByte(_ value: Int) -> String { String(format: "0x%02X", value) }
    var lines = ["{", "  \"colors\" : ["]
    for (index, mode) in Mode.allCases.enumerated() {
        guard let hex = variants[mode] else { throw fail("missing \(mode.rawValue) variant") }
        let color = RGBA(hex: hex)
        var appearances: [(String, String)] = []
        if mode == .dark || mode == .darkHighContrast { appearances.append(("luminosity", "dark")) }
        if mode == .highContrast || mode == .darkHighContrast { appearances.append(("contrast", "high")) }
        lines.append("    {")
        if !appearances.isEmpty {
            lines.append("      \"appearances\" : [")
            for (offset, item) in appearances.enumerated() {
                lines.append("        {")
                lines.append("          \"appearance\" : \"\(item.0)\",")
                lines.append("          \"value\" : \"\(item.1)\"")
                lines.append(offset == appearances.count - 1 ? "        }" : "        },")
            }
            lines.append("      ],")
        }
        lines += [
            "      \"color\" : {",
            "        \"color-space\" : \"srgb\",",
            "        \"components\" : {",
            "          \"alpha\" : \"\(String(format: "%.3f", Double(color.alpha) / 255))\",",
            "          \"blue\" : \"\(hexByte(color.blue))\",",
            "          \"green\" : \"\(hexByte(color.green))\",",
            "          \"red\" : \"\(hexByte(color.red))\"",
            "        }",
            "      },",
            "      \"idiom\" : \"universal\"",
            index == Mode.allCases.count - 1 ? "    }" : "    },",
        ]
    }
    lines += ["  ],", "  \"info\" : {", "    \"author\" : \"xcode\",", "    \"version\" : 1", "  }", "}", ""]
    return lines.joined(separator: "\n")
}

let catalogInfo = """
    {
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """

let namespaceInfo = """
    {
      "info" : {
        "author" : "xcode",
        "version" : 1
      },
      "properties" : {
        "provides-namespace" : true
      }
    }

    """

// MARK: - Swift output

struct ColorToken {
    enum Kind {
        /// A color set in `Tokens/`.
        case asset
        /// `semantic.color.accent`: the AccentColor set, read through `Color.accentColor` so a user accent wins.
        case accent
        /// An alias of the accent: follows the user accent at runtime.
        case accentAlias
        /// Runtime AppKit color named in `$extensions.appkit` (only `border.focus`).
        case keyboardFocus
    }

    let path: String
    let name: String
    let kind: Kind
    let variants: [Mode: String]
    let description: String?
}

func classify(_ tree: TokenTree) throws -> (
    colors: [ColorToken], numbers: [(group: String, path: String, value: Double)]
) {
    var colors: [ColorToken] = []
    var numbers: [(String, String, Double)] = []
    for (path, token) in try tree.leaves(under: "semantic.color") {
        if let value = token["$value"] as? Double {
            let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw fail("number token outside a group: \(path)") }
            numbers.append((parts[0], parts[1], value))
            continue
        }
        let full = "semantic.color.\(path)"
        var variants: [Mode: String] = [:]
        for mode in Mode.allCases { variants[mode] = try tree.color(full, mode: mode) }
        let appkit = TokenTree.extensions(of: token)["appkit"] as? String
        let kind: ColorToken.Kind
        if path == "accent" {
            kind = .accent
        } else if appkit?.hasPrefix("NSColor.keyboardFocusIndicatorColor") == true {
            kind = .keyboardFocus
        } else if appkit != nil {
            throw fail("unsupported appkit mapping at \(full): \(appkit ?? "")")
        } else if token["$value"] as? String == "{semantic.color.accent}" {
            kind = .accentAlias
        } else {
            kind = .asset
        }
        colors.append(
            ColorToken(
                path: path,
                name: camelCase(path),
                kind: kind,
                variants: variants,
                description: token["$description"] as? String
            )
        )
    }
    return (colors, numbers)
}

func valuesComment(_ variants: [Mode: String]) -> String {
    let light = variants[.light] ?? ""
    let dark = variants[.dark] ?? ""
    var parts = ["Light `\(light)`", "Dark `\(dark)`"]
    if let high = variants[.highContrast], high != light { parts.append("High Contrast `\(high)`") }
    if let darkHigh = variants[.darkHighContrast], darkHigh != dark { parts.append("Dark High Contrast `\(darkHigh)`") }
    return parts.joined(separator: " · ")
}

/// Wraps prose into `///` lines that stay inside swift-format's 120-column limit.
func docLines(_ text: String, indent: String) -> [String] {
    let limit = 120 - indent.count - 4
    var lines: [String] = []
    var current = ""
    for word in text.split(separator: " ") {
        if !current.isEmpty, current.count + 1 + word.count > limit {
            lines.append(current)
            current = String(word)
        } else {
            current = current.isEmpty ? String(word) : current + " " + word
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines.map { "\(indent)/// \($0)" }
}

struct SwiftWriter {
    private(set) var lines: [String] = []

    mutating func line(_ text: String = "") { lines.append(text) }

    mutating func doc(_ text: String?, indent: String) {
        guard let text, !text.isEmpty else { return }
        lines += docLines(text, indent: indent)
    }
}

func colorSection(_ colors: [ColorToken], into out: inout SwiftWriter) {
    out.line("    /// Semantic colors. Asset colors carry light, dark, High Contrast, and Dark High Contrast variants.")
    out.line("    enum Color {")
    for token in colors {
        out.doc(token.description, indent: "        ")
        switch token.kind {
        case .asset:
            out.line("        /// \(valuesComment(token.variants))")
            out.line("        static let \(token.name) = SwiftUI.Color(\"Tokens/\(token.name)\", bundle: nil)")
        case .accent:
            out.line(
                "        /// \(valuesComment(token.variants)). The AccentColor asset; a user-chosen system accent wins."
            )
            out.line("        static let \(token.name) = SwiftUI.Color.accentColor")
        case .accentAlias:
            out.line("        /// Alias of `accent`, so it follows a user-chosen system accent.")
            out.line("        static let \(token.name) = SwiftUI.Color.accentColor")
        case .keyboardFocus:
            out.line(
                "        /// The system keyboard focus color (follows the accent). Mockup value: \(valuesComment(token.variants))."
            )
            out.line("        static let \(token.name) = SwiftUI.Color(nsColor: .keyboardFocusIndicatorColor)")
        }
    }
    for (list, prefix, doc) in [
        ("graphLanes", "graphLane", "Lane colors by index; pick with `lane % graphLanes.count` (ADR-0010)."),
        ("graphOnLanes", "graphOnLane", "Text on a solid lane fill, same order as `graphLanes`."),
        ("avatars", "avatar", "Initials avatar fills by index (FNV-1a of the email, mod 8; design-tokens.md §3.5)."),
    ] {
        let members = colors.filter {
            $0.name.hasPrefix(prefix) && $0.name.dropFirst(prefix.count).allSatisfy(\.isNumber)
        }
        guard !members.isEmpty else { continue }
        out.line("        /// \(doc)")
        out.line("        static let \(list): [SwiftUI.Color] = [")
        var row = ""
        for name in members.map(\.name) {
            if !row.isEmpty, 12 + row.count + name.count + 2 > 120 {
                out.line("            " + row)
                row = ""
            }
            row += row.isEmpty ? "\(name)," : " \(name),"
        }
        out.line("            " + row)
        out.line("        ]")
    }
    out.line("    }")
}

func dimensionSection(_ tree: TokenTree, group: String, typeName: String, doc: String, into out: inout SwiftWriter)
    throws
{
    out.line()
    out.line("    /// \(doc)")
    out.line("    enum \(typeName) {")
    for (path, token) in try tree.leaves(under: "semantic.\(group)") {
        out.doc(token["$description"] as? String, indent: "        ")
        let name = camelCase(path)
        switch token["$value"] {
        case let value as Double:
            out.line("        static let \(name) = \(number(value))")
        case let text as String where text.contains("×"):
            let sides = text.components(separatedBy: "×").map { $0.trimmingCharacters(in: .whitespaces) }
            guard sides.count == 2 else { throw fail("bad size \(text) at \(group).\(path)") }
            let width = try pixels(sides[0], at: path)
            let height = try pixels(sides[1], at: path)
            out.line("        static let \(name) = CGSize(width: \(number(width)), height: \(number(height)))")
        case let text as String:
            out.line("        static let \(name): CGFloat = \(number(try pixels(text, at: path)))")
        default:
            throw fail("unsupported value at semantic.\(group).\(path)")
        }
    }
    out.line("    }")
}

func typographySection(_ tree: TokenTree, into out: inout SwiftWriter) throws {
    out.line()
    out.line("    /// Text styles. App code uses these SwiftUI text styles, never point sizes (design-tokens.md §3.6).")
    out.line("    enum Font {")
    for (path, token) in try tree.leaves(under: "semantic.typography") {
        guard let swiftUI = TokenTree.extensions(of: token)["swiftui"] as? String, swiftUI.hasPrefix("Font.") else {
            throw fail("typography token without a swiftui mapping: \(path)")
        }
        out.doc(token["$description"] as? String, indent: "        ")
        out.line("        static let \(camelCase(path)) = SwiftUI.\(swiftUI)")
        guard let value = token["$value"] as? [String: Any], let spacing = value["letterSpacing"] as? String else {
            continue
        }
        guard spacing.hasSuffix("em"), let em = Double(spacing.dropLast(2)),
            let sizeText = value["fontSize"] as? String
        else { throw fail("bad letterSpacing at \(path)") }
        let tracking = em * (try pixels(sizeText, at: path))
        out.line("        /// Tracking for `\(camelCase(path))` (\(spacing) at \(sizeText)).")
        out.line("        static let \(camelCase(path))Tracking: CGFloat = \(number(tracking))")
    }
    out.line("    }")
}

func motionSection(_ tree: TokenTree, into out: inout SwiftWriter) throws {
    out.line()
    out.line(
        "    /// Durations in seconds and easing curves. Under Reduce Motion, cross-fade with `durationFast` or skip.")
    out.line("    enum Motion {")
    for (path, token) in try tree.leaves(under: "semantic.motion") {
        out.doc(token["$description"] as? String, indent: "        ")
        let name = camelCase(path)
        switch (token["$type"] as? String, token["$value"]) {
        case ("duration", let text as String):
            guard text.hasSuffix("ms"), let ms = Double(text.dropLast(2)) else { throw fail("bad duration at \(path)") }
            out.line("        static let \(name): TimeInterval = \(number(ms / 1000))")
        case ("cubicBezier", let points as [Double]) where points.count == 4:
            let p = points.map(number)
            out.line("        /// Control points of `\(name)` (CSS `cubic-bezier(\(p.joined(separator: ", ")))`).")
            out.line(
                "        static let \(name)ControlPoints: (x1: Double, y1: Double, x2: Double, y2: Double) = "
                    + "(\(p.joined(separator: ", ")))"
            )
            out.line("        static let \(name) = UnitCurve.bezier(")
            out.line("            startControlPoint: UnitPoint(x: \(p[0]), y: \(p[1])),")
            out.line("            endControlPoint: UnitPoint(x: \(p[2]), y: \(p[3]))")
            out.line("        )")
        default:
            throw fail("unsupported motion token \(path)")
        }
    }
    out.line("    }")
}

func numberSection(
    _ tree: TokenTree,
    numbers: [(group: String, path: String, value: Double)],
    into out: inout SwiftWriter
) throws {
    out.line()
    out.line("    /// Opacities applied to other colors.")
    out.line("    enum Opacity {")
    for (path, token) in try tree.leaves(under: "semantic.opacity") {
        guard let value = token["$value"] as? Double else { throw fail("bad opacity at \(path)") }
        out.doc(token["$description"] as? String, indent: "        ")
        out.line("        static let \(camelCase(path)) = \(number(value))")
    }
    out.line("    }")
    for group in Set(numbers.map(\.group)).sorted() {
        out.line()
        out.line("    /// Numeric `semantic.color.\(group).*` tokens (opacities of lane colors).")
        out.line("    enum \(group.prefix(1).uppercased() + camelCase(String(group.dropFirst()))) {")
        for item in numbers where item.group == group {
            out.line("        static let \(camelCase(item.path)) = \(number(item.value))")
        }
        out.line("    }")
    }
}

func swiftSource(_ tree: TokenTree, colors: [ColorToken], numbers: [(group: String, path: String, value: Double)])
    throws
    -> String
{
    var out = SwiftWriter()
    out.line("// Generated by scripts/tokens/generate.swift from design/tokens/tokens.json. Do not edit by hand.")
    out.line("// Regenerate with `swift scripts/tokens/generate.swift`; CI fails when this file is out of date.")
    out.line()
    out.line("import AppKit")
    out.line("import SwiftUI")
    out.line()
    out.line(
        "/// Design tokens (docs/design/design-tokens.md). App code reads these, never primitives or literal values.")
    out.line("enum Tokens {")
    colorSection(colors, into: &out)
    try dimensionSection(tree, group: "spacing", typeName: "Spacing", doc: "Spacing scale in points.", into: &out)
    try dimensionSection(tree, group: "radius", typeName: "Radius", doc: "Corner radii in points.", into: &out)
    try dimensionSection(
        tree,
        group: "size",
        typeName: "Size",
        doc: "Row, graph, panel, column, and window sizes in points.",
        into: &out
    )
    try typographySection(tree, into: &out)
    try motionSection(tree, into: &out)
    try numberSection(tree, numbers: numbers, into: &out)
    out.line("}")
    return out.lines.joined(separator: "\n") + "\n"
}

// MARK: - Main

/// Writes only when the content changed, so file timestamps (and Xcode's incremental build) stay put.
func write(_ text: String, to url: URL) throws {
    if let existing = try? String(contentsOf: url, encoding: .utf8), existing == text { return }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

func run() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: repo.appendingPathComponent("design/tokens/tokens.json"))
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw fail("tokens.json is not an object")
    }
    let tree = TokenTree(root: root)
    let (colors, numbers) = try classify(tree)

    let catalog = repo.appendingPathComponent("Overgrove/Resources/Assets.xcassets")
    let tokensFolder = catalog.appendingPathComponent("Tokens")
    try write(catalogInfo, to: catalog.appendingPathComponent("Contents.json"))
    try write(namespaceInfo, to: tokensFolder.appendingPathComponent("Contents.json"))
    guard let accent = colors.first(where: { $0.kind == .accent }) else { throw fail("no semantic.color.accent") }
    try write(
        try colorSetJSON(accent.variants), to: catalog.appendingPathComponent("AccentColor.colorset/Contents.json"))

    let assets = colors.filter { $0.kind == .asset }
    var expected = Set<String>()
    for token in assets {
        let folder = "\(token.name).colorset"
        expected.insert(folder)
        try write(try colorSetJSON(token.variants), to: tokensFolder.appendingPathComponent("\(folder)/Contents.json"))
    }
    let existing = try FileManager.default.contentsOfDirectory(atPath: tokensFolder.path)
    for stale in existing where stale.hasSuffix(".colorset") && !expected.contains(stale) {
        try FileManager.default.removeItem(at: tokensFolder.appendingPathComponent(stale))
    }

    let source = try swiftSource(tree, colors: colors, numbers: numbers)
    try write(source, to: repo.appendingPathComponent("Overgrove/DesignSystem/Tokens.generated.swift"))
    print("tokens: \(assets.count) color sets + AccentColor, Tokens.generated.swift")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("generate.swift: \(error)\n".utf8))
    exit(1)
}
