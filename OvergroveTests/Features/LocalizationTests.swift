import Foundation
import XCTest

@testable import Overgrove

/// Korean localization (#120, docs/glossary.md "한국어 UI 표기 규칙"). Tests run in English (the scheme's test language),
/// so the other tests can compare English text; this file checks the catalog and the Korean bundle on their own.
final class LocalizationTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let catalog = repo.appendingPathComponent("Overgrove/Resources/Localizable.xcstrings")

    /// A key with no letters once its placeholders are removed (`%@ (%@)`, `#%lld`, spacing) needs no Korean: it reads
    /// the same in every language.
    private static func needsTranslation(_ key: String) -> Bool {
        let bare = key.replacingOccurrences(
            of: "%(?:[0-9]+\\$)?(?:@|lld|ld|d)", with: "", options: .regularExpression)
        return bare.rangeOfCharacter(from: .letters) != nil
    }

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

    /// Every string the compiler extracts anywhere in the app (the build's `.stringsdata`) has Korean (#454: the whole
    /// app, not a list of screens). Text that must stay English (Copy Report, git's and gh's own output, copyable
    /// commands) is never extracted in the first place.
    func testEveryExtractedStringHasKorean() throws {
        let strings = try catalogStrings()
        let objects = try XCTUnwrap(Self.objectDirectories(), "build intermediates not found next to the app")
        var checked = 0
        var missing: [String] = []
        for directory in objects {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "stringsdata" }
            for file in files {
                for key in try Self.extractedKeys(file) where Self.needsTranslation(key) {
                    checked += 1
                    if strings[key].flatMap(korean) == nil {
                        missing.append("\(file.deletingPathExtension().lastPathComponent).swift: “\(key)”")
                    }
                }
            }
        }
        XCTAssertEqual(missing.sorted(), [], "strings without Korean")
        XCTAssertGreaterThan(checked, 600)
    }

    /// Copy Report (#110) is never localized (docs/glossary.md, #454): the report builder extracts no keys, so the
    /// copied text is English in every language. Its rows keep English titles; the screen shows `displayTitle`.
    func testCopyReportStaysEnglish() throws {
        let objects = try XCTUnwrap(Self.objectDirectories(), "build intermediates not found next to the app")
        for file in objects.map({ $0.appendingPathComponent("SecurityReport.stringsdata") })
        where FileManager.default.fileExists(atPath: file.path) {
            XCTAssertEqual(try Self.extractedKeys(file), [], "SecurityReport.swift must not localize")
        }
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

    /// The diff viewer's notices, block titles and facts (#494) are looked up in the catalog, not built as plain
    /// strings: each key is extracted from `DiffDocument.swift` and has Korean.
    func testDiffViewerStringsAreLocalized() throws {
        let objects = try XCTUnwrap(Self.objectDirectories(), "build intermediates not found next to the app")
        let file = try XCTUnwrap(
            objects.map { $0.appendingPathComponent("DiffDocument.stringsdata") }
                .first { FileManager.default.fileExists(atPath: $0.path) })
        let extracted = Set(try Self.extractedKeys(file))
        let expected = [
            "No changes. The file matches the other side.",
            "Conflicted file. The combined diff is not shown yet; resolve it in Terminal.",
            "Binary file. Its contents are not shown.",
            "Submodule commit %@ → %@",
            "none",
            "Deleted file", "Deleted symbolic link", "Added file", "Added symbolic link", "Changed",
            "Renamed from %@", "Renamed from %@ (%lld%%)", "Copied from %@", "Copied from %@ (%lld%%)",
            "Mode %@ → %@",
            "Symbolic link: the link target text is shown",
            "%@ more characters",
        ]
        let strings = try catalogStrings()
        for key in expected {
            XCTAssertTrue(extracted.contains(key), "not extracted: \(key)")
            XCTAssertNotNil(strings[key].flatMap(korean), "no Korean: \(key)")
        }
    }

    /// The issue detail's Labels and Assignees headings (#502) are looked up in the catalog and have Korean.
    func testIssueDetailHeadingsAreLocalized() throws {
        let objects = try XCTUnwrap(Self.objectDirectories(), "build intermediates not found next to the app")
        let file = try XCTUnwrap(
            objects.map { $0.appendingPathComponent("IssueViews.stringsdata") }
                .first { FileManager.default.fileExists(atPath: $0.path) })
        let extracted = try Self.extractedKeys(file)
        let ko = try XCTUnwrap(Bundle.main.path(forResource: "ko", ofType: "lproj").flatMap(Bundle.init(path:)))
        for (key, korean) in [("Labels", "라벨"), ("Assignees", "담당자")] {
            XCTAssertTrue(extracted.contains(key), "not extracted: \(key)")
            XCTAssertEqual(ko.localizedString(forKey: key, value: nil, table: nil), korean)
        }
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
