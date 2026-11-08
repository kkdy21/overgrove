import Foundation
import XCTest

@testable import Overgrove

/// Korean localization (#120, docs/glossary.md "한국어 UI 표기 규칙"). Tests run in English (the scheme's test language),
/// so the other tests can compare English text; this file checks the catalog and the Korean bundle on their own.
final class LocalizationTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let catalog = repo.appendingPathComponent("Overgrove/Resources/Localizable.xcstrings")

    /// Stage 1 screens (#120): every string the compiler extracts from these files must have Korean. Screens other
    /// PRs are changing (sidebar, status bar, issue panel, S-05) come in stage 2 and are not listed yet.
    private static let stageOneSources = [
        "SettingsView", "GitExecutableSettingsView", "GitExecutableSettingsModel", "SetupAssistantView",
        "GraphHeaderViews", "GraphColumnLayout", "GraphAuthorFilter", "DiffViewerView", "NavigationCommands",
        "SearchCommands", "GraphZoomCommands", "OvergroveApp",
    ]
    /// Files with stage 1 strings among others: only these keys are checked.
    private static let stageOneKeysIn = ["PanelChrome": Set(["Graph", "History"])]

    private func catalogStrings() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: Self.catalog)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["sourceLanguage"] as? String, "en")
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }

    private func korean(_ entry: [String: Any]) -> (state: String, value: String)? {
        guard let localizations = entry["localizations"] as? [String: Any],
            let ko = localizations["ko"] as? [String: Any], let unit = ko["stringUnit"] as? [String: Any],
            let state = unit["state"] as? String, let value = unit["value"] as? String
        else { return nil }
        return (state, value)
    }

    private func placeholders(_ text: String) throws -> [String] {
        let pattern = try NSRegularExpression(pattern: "%(?:[0-9]+\\$)?(@|lld|ld|d)")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range)
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
            .sorted()
    }

    /// Every Korean value is translated and keeps the key's placeholders (positional forms like `%2$@` allowed), so a
    /// translation can never ask for an argument the code does not pass.
    func testTranslationsKeepTheirPlaceholders() throws {
        for (key, entry) in try catalogStrings() {
            guard let ko = korean(entry) else { continue }
            XCTAssertEqual(ko.state, "translated", key)
            XCTAssertFalse(ko.value.trimmingCharacters(in: .whitespaces).isEmpty, key)
            XCTAssertEqual(try placeholders(ko.value), try placeholders(key), key)
        }
    }

    /// The strings the compiler extracted from the stage 1 sources (the build's `.stringsdata`) all have Korean.
    func testStageOneStringsAreTranslated() throws {
        let strings = try catalogStrings()
        let objects = try XCTUnwrap(Self.objectDirectories(), "build intermediates not found next to the app")
        var checked = 0
        for name in Self.stageOneSources + Array(Self.stageOneKeysIn.keys) {
            let files = objects.map { $0.appendingPathComponent("\(name).stringsdata") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            XCTAssertFalse(files.isEmpty, "no strings extracted from \(name).swift")
            for file in files {
                for key in try Self.extractedKeys(file) where Self.stageOneKeysIn[name]?.contains(key) ?? true {
                    checked += 1
                    XCTAssertNotNil(strings[key].flatMap(korean), "\(name).swift: no Korean for “\(key)”")
                }
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }

    /// The Korean table is in the app bundle and translates; the tests themselves run in English.
    func testKoreanBundleAndEnglishTests() throws {
        XCTAssertEqual(Bundle.main.preferredLocalizations.first, "en", "the scheme's test language is English")
        XCTAssertEqual(String(localized: "Fetch"), "Fetch")
        let path = try XCTUnwrap(Bundle.main.path(forResource: "ko", ofType: "lproj"))
        let ko = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(ko.localizedString(forKey: "Fetch", value: nil, table: nil), "페치")
        XCTAssertEqual(
            ko.localizedString(forKey: "Settings", value: "Settings", table: nil), "Settings",
            "stage 2 keys fall back to English")
        XCTAssertEqual(ko.localizedString(forKey: "Step %lld, done", value: nil, table: nil), "%lld단계, 완료")
    }

    /// `…/Build/Products/<config>/Overgrove.app` → `…/Build/Intermediates.noindex/Overgrove.build/<config>/
    /// Overgrove.build/Objects-normal/<arch>`.
    private static func objectDirectories() -> [URL]? {
        let products = Bundle.main.bundleURL.deletingLastPathComponent()
        let configuration = products.lastPathComponent
        let build = products.deletingLastPathComponent().deletingLastPathComponent()
        let objects = build.appendingPathComponent(
            "Intermediates.noindex/Overgrove.build/\(configuration)/Overgrove.build/Objects-normal")
        guard let archs = try? FileManager.default.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil),
            !archs.isEmpty
        else { return nil }
        return archs
    }

    private static func extractedKeys(_ file: URL) throws -> [String] {
        let data = try Data(contentsOf: file)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tables = root?["tables"] as? [String: Any]
        let entries = tables?["Localizable"] as? [[String: Any]] ?? []
        return entries.compactMap { $0["key"] as? String }
    }
}
