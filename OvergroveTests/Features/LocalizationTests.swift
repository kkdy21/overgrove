import Foundation
import XCTest

@testable import Overgrove

/// Korean localization (#120, docs/glossary.md "한국어 UI 표기 규칙"). Tests run in English (the scheme's test language),
/// so the other tests can compare English text; this file checks the catalog and the Korean bundle on their own.
final class LocalizationTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let catalog = repo.appendingPathComponent("Overgrove/Resources/Localizable.xcstrings")

    /// Translated screens: every string the compiler extracts from these files must have Korean. Stage 1 (#120) and
    /// the screens of #454 so far; the status bar's gh field and the issue panel come later.
    private static let translatedSources = [
        // #120
        "SettingsView", "GitExecutableSettingsView", "GitExecutableSettingsModel", "SetupAssistantView",
        "GraphHeaderViews", "GraphColumnLayout", "GraphAuthorFilter", "DiffViewerView", "NavigationCommands",
        "SearchCommands", "GraphZoomCommands", "OvergroveApp",
        // #454: S-03, S-04, S-09, S-11, S-12, the sidebar's worktree, branch, tag, and stash sections, row menus
        "CommitDetailView", "CommitDetailModel", "StashViews", "StashModels", "FileHistoryView", "FileHistoryModel",
        "CommitComparisonView", "CommitComparisonModel", "ComparisonView", "ComparisonModel", "BranchListModel",
        "BranchListSection", "TagListModel", "TagListSection", "WorktreeListModel", "WorktreeListSection", "RowMenu",
        "GraphRowModel", "AppState+Comparison",
        // #454: S-02, submodules, search, the toolbar, the repository switcher, fetch details, Settings › Apps
        "WipDetailModel", "WipDetailView", "SubmoduleSectionModel", "SubmoduleSectionView", "GraphSearch",
        "RepositorySwitcher", "FetchFailureDetailsView", "MainToolbar", "ExternalAppsSettingsView", "GraphView",
        // #454: the Terminal confirmation and repository registration messages
        "TerminalGuard", "AppState+Registration", "RepositoryRegistrar",
        // #454: S-05 (the Copy Report text stays English: SecurityReportTests)
        "WorktreeDetailModel", "WorktreeDetailView",
        // #454: summaries and guidance the app writes; git's and gh's own output and copyable commands stay as they are
        "GitError", "FetchFailureGuidance",
        // #454: the PR pill and the S-05 Pull request card (#115)
        "PullRequestModels", "PullRequestViews",
    ]
    /// Files with translated strings among others: only these keys are checked.
    private static let translatedKeysIn = [
        "PanelChrome": Set([
            "Graph", "History", "No repository open", "Add a repository to see its worktrees.", "History unavailable",
            "Commit graph", "The history of every worktree appears here.", "Open a repository to see its history.",
            "Commit %@", "No selection", "Details",
            "Changes in the focused worktree or the selected commit appear here.",
            "Commits", "Loading history…",
        ]),
        "StatusBar": Set(["just now", "%lld min ago", "%lld h ago", "%lld d ago"]),
        "ExternalApps": Set(["Terminal", "Editor"]),
        "GHStatusGuidanceView": Set(["Copy", "Copy command %@"]),
    ]

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

    /// The strings the compiler extracted from the translated sources (the build's `.stringsdata`) all have Korean.
    func testTranslatedSourcesHaveKorean() throws {
        let strings = try catalogStrings()
        let objects = try XCTUnwrap(Self.objectDirectories(), "build intermediates not found next to the app")
        var checked = 0
        for name in Self.translatedSources + Array(Self.translatedKeysIn.keys) {
            let files = objects.map { $0.appendingPathComponent("\(name).stringsdata") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            XCTAssertFalse(files.isEmpty, "no strings extracted from \(name).swift")
            for file in files {
                for key in try Self.extractedKeys(file) where Self.translatedKeysIn[name]?.contains(key) ?? true {
                    checked += 1
                    XCTAssertNotNil(strings[key].flatMap(korean), "\(name).swift: no Korean for “\(key)”")
                }
            }
        }
        XCTAssertGreaterThan(checked, 250)
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
