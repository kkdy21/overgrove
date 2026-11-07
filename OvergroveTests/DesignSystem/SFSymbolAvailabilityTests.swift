import AppKit
import XCTest

/// Every SF Symbol the app or the icon spec names exists on the minimum macOS (#40, iconography.md §5).
///
/// `NSImage(systemSymbolName:)` only says whether a symbol exists on the macOS running the tests, which is newer
/// than the minimum. The availability comes from the system's SF Symbols metadata instead:
/// `CoreGlyphs.bundle/…/name_availability.plist` maps each symbol name to the SF Symbols release that added it, and
/// each release to its first macOS (2023 → macOS 14.0). The minimum is `MACOSX_DEPLOYMENT_TARGET` in
/// `Config/Base.xcconfig`, so raising or lowering it re-checks every symbol.
final class SFSymbolAvailabilityTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let metadata = URL(
        fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")

    /// String literals that happen to be symbol names but are not used as symbols: `"cat"` as the pager in the git
    /// and gh environments, `"a"` as a C escape in `PatchParser`, `"left"`/`"right"` as `rev-list` field names, and
    /// `` `2h` `` as a relative time in screens.md.
    private static let notSymbols: Set<String> = ["a", "cat", "left", "right", "2h"]

    private struct Availability {
        /// Symbol name → SF Symbols release (`"2023"`, `"2022.1"`).
        let symbols: [String: String]
        /// Release → first macOS version.
        let macOS: [String: String]

        func firstMacOS(_ name: String) -> [Int]? {
            symbols[name].flatMap { macOS[$0] }.map(SFSymbolAvailabilityTests.version)
        }
    }

    private func availability() throws -> Availability {
        guard let data = try? Data(contentsOf: Self.metadata),
            let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let symbols = root["symbols"] as? [String: String],
            let releases = root["year_to_release"] as? [String: [String: String]]
        else { throw XCTSkip("SF Symbols availability metadata is not on this system") }
        return Availability(symbols: symbols, macOS: releases.compactMapValues { $0["macOS"] })
    }

    private static func version(_ text: String) -> [Int] {
        text.split(separator: ".").compactMap { Int($0) }
    }

    private static func isNewer(_ lhs: [Int], than rhs: [Int]) -> Bool {
        for index in 0..<max(lhs.count, rhs.count) {
            let (left, right) = (index < lhs.count ? lhs[index] : 0, index < rhs.count ? rhs[index] : 0)
            if left != right { return left > right }
        }
        return false
    }

    private func deploymentTarget() throws -> [Int] {
        let config = try String(contentsOf: Self.repo.appendingPathComponent("Config/Base.xcconfig"), encoding: .utf8)
        let line = try XCTUnwrap(
            config.split(separator: "\n").first { $0.hasPrefix("MACOSX_DEPLOYMENT_TARGET") }, "deployment target")
        let value = try XCTUnwrap(line.split(separator: "=").last).trimmingCharacters(in: .whitespaces)
        return Self.version(value)
    }

    private func sources() throws -> [(path: String, text: String)] {
        let root = Self.repo.appendingPathComponent("Overgrove")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return try files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map {
            (
                $0.path.replacingOccurrences(of: Self.repo.path + "/", with: ""),
                try String(contentsOf: $0, encoding: .utf8)
            )
        }
    }

    private func matches(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Names passed straight to a symbol API (`Image(systemName:)`, `Label(_:systemImage:)`,
    /// `NSImage(systemSymbolName:)`), without interpolation.
    private func apiNames() throws -> [(name: String, path: String)] {
        try sources().flatMap { file in
            try matches(#"(?:systemName|systemImage|systemSymbolName)\s*:\s*"([^"\\]+)""#, in: file.text).map {
                ($0, file.path)
            }
        }
    }

    /// Every symbol the app names: the API arguments, and any other string literal that is a symbol name (the
    /// `symbol` properties of models and views return them from a `switch`).
    private func appSymbols(_ availability: Availability) throws -> Set<String> {
        var names = Set(try apiNames().map(\.name))
        for file in try sources() {
            for literal in try matches(#""([a-z0-9][a-z0-9.]*)""#, in: file.text)
            where availability.symbols[literal] != nil && !Self.notSymbols.contains(literal) {
                names.insert(literal)
            }
        }
        return names
    }

    func testEverySymbolPassedToASymbolAPIIsARealSymbol() throws {
        let availability = try availability()
        let unknown = try apiNames().filter { availability.symbols[$0.name] == nil }
        XCTAssertTrue(unknown.isEmpty, "not SF Symbols names: \(unknown.map { "\($0.name) in \($0.path)" })")
    }

    func testEveryAppSymbolExistsOnTheMinimumMacOS() throws {
        let availability = try availability()
        let minimum = try deploymentTarget()
        let names = try appSymbols(availability)
        XCTAssertGreaterThan(names.count, 40, "the scan found the app's symbols")
        for name in names.sorted() {
            let first = try XCTUnwrap(availability.firstMacOS(name), "\(name): no availability")
            XCTAssertFalse(
                Self.isNewer(first, than: minimum),
                "\(name) needs macOS \(first.map(String.init).joined(separator: ".")); pick a replacement")
        }
    }

    /// The setup assistant draws `1.circle`–`3.circle` from the step number (`SetupStepCard`).
    func testNumberedStepSymbolsExistOnTheMinimumMacOS() throws {
        let availability = try availability()
        let minimum = try deploymentTarget()
        for step in 1...3 {
            let first = try XCTUnwrap(availability.firstMacOS("\(step).circle"), "\(step).circle")
            XCTAssertFalse(Self.isNewer(first, than: minimum), "\(step).circle")
        }
    }

    /// The symbols iconography.md and screens.md name, whether or not the app uses them yet.
    func testEverySymbolInTheIconSpecExistsOnTheMinimumMacOS() throws {
        let availability = try availability()
        let minimum = try deploymentTarget()
        var names = Set<String>()
        for document in ["docs/design/iconography.md", "docs/design/screens.md"] {
            let text = try String(contentsOf: Self.repo.appendingPathComponent(document), encoding: .utf8)
            for name in try matches(#"`([a-z0-9][a-z0-9.]*)`"#, in: text)
            where availability.symbols[name] != nil && !Self.notSymbols.contains(name) {
                names.insert(name)
            }
        }
        XCTAssertGreaterThan(names.count, 40, "the scan found the spec's symbols")
        for name in names.sorted() {
            let first = try XCTUnwrap(availability.firstMacOS(name), name)
            XCTAssertFalse(Self.isNewer(first, than: minimum), "\(name) in the spec needs a newer macOS")
        }
    }

    /// And on the macOS running the tests, AppKit draws them.
    func testEveryAppSymbolResolvesOnThisMacOS() throws {
        for name in try appSymbols(try availability()).sorted() {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }

    func testVersionComparison() {
        XCTAssertTrue(Self.isNewer([14, 1], than: [14]))
        XCTAssertFalse(Self.isNewer([14, 0], than: [14]))
        XCTAssertFalse(Self.isNewer([13, 3], than: [14, 0]))
        XCTAssertTrue(Self.isNewer([15], than: [14, 6]))
    }
}
