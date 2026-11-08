import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import Overgrove

/// SEC-T14-13: a user-chosen terminal and editor (#124). Only a checked bundle identifier is kept, apps open through
/// `NSWorkspace` with one checked URL (no shell, process, or arguments), a folder whose settings can run code asks
/// first, and a file whose real location is outside the worktree is refused.
@MainActor
final class ExternalAppsTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("overgrove-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suite = "overgrove-apps-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    /// A minimal application bundle; `info` overrides Info.plist keys (`nil` removes one).
    private func makeApp(_ name: String, info: [String: String?] = [:], executable: Bool = true) throws -> URL {
        let app = base.appendingPathComponent(name)
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var plist: [String: String] = [
            "CFBundleIdentifier": "com.example.editor", "CFBundleExecutable": "editor", "CFBundleName": "Example",
            "CFBundlePackageType": "APPL",
        ]
        for (key, value) in info { plist[key] = value }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        if executable {
            let binary = macOS.appendingPathComponent(plist["CFBundleExecutable"] ?? "editor")
            try Data("not a program\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return app
    }

    func testBundleIdentifiers() {
        for valid in ["com.apple.Terminal", "com.microsoft.VSCode", "dev.zed.Zed-Preview", "a"] {
            XCTAssertTrue(ExternalApps.isValidBundleIdentifier(valid), valid)
        }
        for invalid in ["", ".com.x", "-x", "com.x;rm", "com x", "com/x", "cöm.x", String(repeating: "a", count: 256)] {
            XCTAssertFalse(ExternalApps.isValidBundleIdentifier(invalid), invalid)
        }
    }

    func testInspectingAChosenApp() throws {
        let good = try makeApp("Good.app", info: ["CFBundleDisplayName": "Good\u{1B}[31m Editor"])
        let info = try ExternalApps.inspect(good, isAppleSigned: { _ in false }).get()
        XCTAssertEqual(info.bundleIdentifier, "com.example.editor")
        XCTAssertFalse(info.name.contains("\u{1B}"), "the bundle's name is escaped for display")
        XCTAssertFalse(info.isAppleSigned)

        let folder = base.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(ExternalApps.inspect(folder, isAppleSigned: { _ in false }), .failure(.notAnApp))
        let noID = try makeApp("NoID.app", info: ["CFBundleIdentifier": nil])
        XCTAssertEqual(ExternalApps.inspect(noID, isAppleSigned: { _ in false }), .failure(.noBundleIdentifier))
        let badID = try makeApp("Bad.app", info: ["CFBundleIdentifier": "com.x;open -a Calculator"])
        XCTAssertEqual(ExternalApps.inspect(badID, isAppleSigned: { _ in false }), .failure(.noBundleIdentifier))
        let noExecutable = try makeApp("NoExec.app", executable: false)
        XCTAssertEqual(ExternalApps.inspect(noExecutable, isAppleSigned: { _ in false }), .failure(.noExecutable))
    }

    func testChoicesAreStoredAndCheckedWhenRead() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.terminalApp)
        XCTAssertEqual(settings.terminalBundleIdentifier, ExternalApps.defaultTerminal)
        XCTAssertNil(settings.editorApp)
        settings.terminalApp = "com.googlecode.iterm2"
        settings.editorApp = "com.microsoft.VSCode"
        let reread = AppSettings(defaults: defaults)
        XCTAssertEqual(reread.terminalBundleIdentifier, "com.googlecode.iterm2")
        XCTAssertEqual(reread.editorApp, "com.microsoft.VSCode")

        defaults.set("/Applications/Evil.app; rm -rf ~", forKey: AppSettings.editorAppKey)
        XCTAssertNil(AppSettings(defaults: defaults).editorApp, "a stored value that is not an identifier is ignored")
    }

    // MARK: - Opening

    private func state(settings: AppSettings, inspection: RepoConfigInspection?) async throws -> (
        AppState, RecordingRowActions, URL
    ) {
        let root = try XCTUnwrap(PathValidator.canonical(base)).appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        let mock = WorktreeListing.entry(
            root.path, branch: "main", isMain: true, state: .loaded(WorktreeListing.state(branch: "main")))
        let listing = WorktreeListing(
            entries: [WorktreeListing.Entry(worktree: mock.worktree, state: mock.state, inspection: inspection)],
            isPartial: false)
        let actions = RecordingRowActions()
        actions.installed["com.example.editor"] = "Example"
        actions.installed["com.googlecode.iterm2"] = "iTerm"
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(listing)), graphLoader: SampleGraphLoader(),
            commitLoader: StubCommitLoader(), settings: settings)
        state.rowActions = actions
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        return (state, actions, root)
    }

    private func clean() -> RepoConfigInspection {
        RepoConfigInspector.inspect(ConfigParser.Listing(entries: [], isPartial: false))
    }

    func testTheChosenTerminalOpensTheFolder() async throws {
        let settings = AppSettings(defaults: defaults)
        settings.terminalApp = "com.googlecode.iterm2"
        let (state, actions, root) = try await state(settings: settings, inspection: clean())
        state.openTerminal(at: GitPath(root.path))
        XCTAssertNil(state.terminalConfirmation)
        XCTAssertEqual(actions.openedInApps.map(\.app), ["com.googlecode.iterm2"])
        XCTAssertEqual(actions.openedInApps.first?.item.standardizedFileURL, root.standardizedFileURL)
    }

    /// An editor runs workspace settings and tasks, so a folder with findings asks first, naming the editor.
    func testEditorFolderIsGuardedAndAFileIsNot() async throws {
        let settings = AppSettings(defaults: defaults)
        settings.editorApp = "com.example.editor"
        let risky = RepoConfigInspector.inspect(
            ConfigParser.Listing(
                entries: [
                    ConfigEntry(scope: .local, section: "core", subsection: nil, variable: "fsmonitor", value: "x")
                ],
                isPartial: false))
        let (state, actions, root) = try await state(settings: settings, inspection: risky)
        XCTAssertTrue(state.rowMenuActions.hasEditor)

        state.openEditor(at: GitPath(root.path))
        let confirmation = try XCTUnwrap(state.terminalConfirmation)
        XCTAssertEqual(confirmation.title, "Open in Example?")
        XCTAssertEqual(confirmation.role, .editor)
        XCTAssertTrue(confirmation.message.hasPrefix("Editors and their extensions"), confirmation.message)
        XCTAssertTrue(actions.openedInApps.isEmpty, "nothing opens until Open Anyway")
        state.confirmOpenTerminal()
        XCTAssertEqual(actions.openedInApps.map(\.app), ["com.example.editor"])

        state.openFileInEditor(GitPath("a.txt"), in: GitPath(root.path))
        XCTAssertNil(state.terminalConfirmation, "one file opens without asking")
        XCTAssertEqual(actions.openedInApps.last?.item.lastPathComponent, "a.txt")

        let outside = base.appendingPathComponent("outside.txt")
        try Data("y\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
        state.openFileInEditor(GitPath("link.txt"), in: GitPath(root.path))
        XCTAssertNotNil(state.alert, "a file whose real location is outside the worktree is refused (T14)")
        XCTAssertEqual(actions.openedInApps.count, 2)
    }

    func testWithoutAnEditorNothingOpensAndAMissingAppSaysSo() async throws {
        let settings = AppSettings(defaults: defaults)
        let (state, actions, root) = try await state(settings: settings, inspection: clean())
        XCTAssertFalse(state.rowMenuActions.hasEditor)
        state.openEditor(at: GitPath(root.path))
        XCTAssertTrue(actions.openedInApps.isEmpty)

        settings.terminalApp = "com.example.uninstalled"
        state.openTerminal(at: GitPath(root.path))
        XCTAssertEqual(state.alert?.title, "Can’t Open in Terminal")
        XCTAssertTrue(actions.openedInApps.isEmpty)
    }

    /// Settings › Advanced › Apps, rendered with a chosen editor that is not installed.
    func testAppsSectionRenders() throws {
        let settings = AppSettings(defaults: defaults)
        settings.editorApp = "com.example.uninstalled"
        XCTAssertEqual(
            ExternalAppsSection.summary("com.example.uninstalled", nil, isInstalled: false),
            "com.example.uninstalled · not installed")
        XCTAssertEqual(
            ExternalAppsSection.summary(
                "com.example.editor",
                ExternalAppInfo(bundleIdentifier: "com.example.editor", name: "Example", isAppleSigned: false),
                isInstalled: true),
            "com.example.editor · Not signed by Apple")
        for (mode, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = Form { ExternalAppsSection(settings: settings, locate: { _ in nil }) }.formStyle(.grouped)
            let size = CGSize(width: SettingsView.width, height: 260)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings-apps-\(mode).png"))
            }
        }
    }
}
