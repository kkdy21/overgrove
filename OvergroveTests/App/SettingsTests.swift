import Foundation
import XCTest

@testable import Overgrove

/// S-08 settings (#86): stored preferences, remote URL display (T11), and the Settings › Repositories actions.
@MainActor
final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsAreOff() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.autoFetch, "auto fetch is off by default (S-08, #79)")
        XCTAssertEqual(settings.autoFetchIntervalMinutes, 10)
        XCTAssertFalse(settings.showsFullRemoteURLs)
        XCTAssertFalse(AppSettings.isAutoFetchAvailable, "the toggle stays hidden until the scheduler lands (#79)")
    }

    func testChangesAreKept() {
        let settings = AppSettings(defaults: defaults)
        settings.autoFetch = true
        settings.autoFetchIntervalMinutes = 30
        settings.showsFullRemoteURLs = true
        let reopened = AppSettings(defaults: defaults)
        XCTAssertTrue(reopened.autoFetch)
        XCTAssertEqual(reopened.autoFetchIntervalMinutes, 30)
        XCTAssertTrue(reopened.showsFullRemoteURLs)
    }

    /// An edited preference file cannot set an interval the UI does not offer (e.g. 0 or one second).
    func testUnknownIntervalFallsBackToTheDefault() {
        defaults.set(0, forKey: AppSettings.autoFetchIntervalKey)
        XCTAssertEqual(AppSettings(defaults: defaults).autoFetchIntervalMinutes, 10)
        let settings = AppSettings(defaults: defaults)
        settings.autoFetchIntervalMinutes = 1
        XCTAssertEqual(settings.autoFetchIntervalMinutes, 10)
    }
}

/// `RemoteURLDisplay` (#86, T11): host and path by default, the full masked URL when asked; never credentials.
final class RemoteURLDisplayTests: XCTestCase {
    func testShortForms() {
        XCTAssertEqual(RemoteURLDisplay.short("https://github.com/acme/api.git"), "github.com/acme/api")
        XCTAssertEqual(RemoteURLDisplay.short("https://***@github.com:443/acme/api.git/"), "github.com/acme/api")
        XCTAssertEqual(RemoteURLDisplay.short("ssh://git@github.com:2222/acme/api"), "github.com/acme/api")
        XCTAssertEqual(RemoteURLDisplay.short("git@github.com:acme/api.git"), "github.com/acme/api")
        XCTAssertEqual(RemoteURLDisplay.short("/srv/git/api.git"), "/srv/git/api.git", "a local path has no host")
        XCTAssertEqual(RemoteURLDisplay.short("file:///srv/git/api.git"), "/srv/git/api")
    }

    /// The input is the masked URL, so neither form contains the secret; the full form keeps the mask visible.
    func testCredentialsNeverAppear() {
        let raw = "https://alice:s3cr3t@example.com/repo.git"
        let masked = CredentialMasker.mask(raw)
        for full in [false, true] {
            let text = RemoteURLDisplay.text(masked, full: full)
            XCTAssertFalse(text.contains("s3cr3t"), "full=\(full): \(text)")
            XCTAssertFalse(text.contains("alice"), "full=\(full): \(text)")
        }
        XCTAssertEqual(RemoteURLDisplay.text(masked, full: false), "example.com/repo")
        XCTAssertEqual(RemoteURLDisplay.text(masked, full: true), masked)
    }

    /// Security review of #86: the short form never names a host git would not use.
    func testCraftedURLsAreNotShortenedToAnotherHost() {
        // git reads this as scp-style SSH to evil.example; the short form must say so.
        XCTAssertEqual(
            RemoteURLDisplay.short("git@evil.example:x/https://github.com/acme/api"),
            "evil.example/x/https://github.com/acme/api")
        // A local path that contains `://` is a path.
        XCTAssertEqual(RemoteURLDisplay.short("/tmp/https://github.com/acme/api"), "/tmp/https://github.com/acme/api")
        // Remote helpers are shown whole.
        let helper = "ext::sh -c x https://***@github.com/acme/api"
        XCTAssertEqual(RemoteURLDisplay.short(helper), helper)
        XCTAssertEqual(RemoteURLDisplay.short("persistent-https::https://github.com/a/b"), "persistent-https::https://github.com/a/b")
        // Not a scheme before `://`.
        XCTAssertEqual(RemoteURLDisplay.short("1http://github.com/a"), "1http://github.com/a")
        XCTAssertEqual(RemoteURLDisplay.short("ht tp://github.com/a"), "ht tp://github.com/a")
    }

    func testAuthorityEdgeCases() {
        XCTAssertEqual(RemoteURLDisplay.short("https://[::1]:8080/x.git"), "[::1]/x")
        XCTAssertEqual(RemoteURLDisplay.short("https://[::1/x"), "https://[::1/x", "malformed: shown whole")
        XCTAssertEqual(RemoteURLDisplay.short("https://***@***@example.com/r"), "example.com/r", "last @ wins")
        let long = "https://example.com/" + String(repeating: "a/", count: 50_000)
        XCTAssertTrue(RemoteURLDisplay.short(long).hasPrefix("example.com/a/a"))
    }

    func testControlCharactersAreEscaped() {
        let text = RemoteURLDisplay.text("https://example.com/a\u{202E}b\n", full: true)
        XCTAssertFalse(text.contains("\u{202E}"))
        XCTAssertFalse(text.contains("\n"))
    }
}

/// Settings › Repositories (#86) and windows that show a removed repository.
@MainActor
final class RepositoryListActionsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var base: URL!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let temporary = try XCTUnwrap(PathValidator.canonical(FileManager.default.temporaryDirectory))
        base = temporary.appendingPathComponent("overgrove-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: base)
    }

    private func repositoryFolder(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return url
    }

    private func probe(root: URL) -> RepositoryRegistrar {
        RepositoryRegistrar(probe: { kind, _ in
            switch kind {
            case .gitDirectory: Data("\(root.path)/.git\n\(root.path)/.git\nfalse\ntrue\n".utf8)
            case .worktree: Data("\(root.path)\n\(root.path)/.git\nfalse\n".utf8)
            }
        })
    }

    func testAddAndRemove() async throws {
        let api = try repositoryFolder("api")
        let registry = RepositoryRegistry(defaults: defaults)
        let records = FetchRecordStore(defaults: defaults)
        let loader = TriggerRecordingLoader()
        let actions = RepositoryListActions(
            registry: registry, registrar: probe(root: api), fetchRecords: records, loader: loader)

        let added = await actions.add(api)
        XCTAssertEqual(added, .added(notice: nil))
        let entry = try XCTUnwrap(registry.repositories.first)
        XCTAssertEqual(entry.rootPath, api.path)

        let again = await actions.add(api)
        XCTAssertEqual(again, .alreadyRegistered(name: entry.name, path: entry.displayRootPath))

        records.save(FetchRecord(repositoryID: entry.repository.id, finishedAt: Date(), succeeded: true, summary: nil))
        actions.remove(entry.id)
        XCTAssertEqual(registry.repositories, [])
        XCTAssertNil(records.entry(for: entry.repository.id), "its fetch record goes too")
        let deadline = ContinuousClock.now + .seconds(5)
        while loader.forgotten.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(loader.forgotten, [entry.repository.id], "its cached results go too")
        XCTAssertTrue(FileManager.default.fileExists(atPath: api.path), "the folder is not touched")
    }

    func testAddRefusesAFolderThatIsNotARepository() async throws {
        let plain = base.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let actions = RepositoryListActions(
            registry: RepositoryRegistry(defaults: defaults),
            registrar: RepositoryRegistrar(probe: { _, _ in
                throw GitError.notARepository(detail: MaskedText(masking: ""))
            }),
            fetchRecords: FetchRecordStore(defaults: defaults), loader: TriggerRecordingLoader())
        guard case .failed = await actions.add(plain) else { return XCTFail("a refusal is reported") }
    }

    /// A window showing a repository removed in Settings closes it.
    func testWindowClosesARepositoryRemovedElsewhere() async throws {
        let api = try repositoryFolder("api")
        let registry = RepositoryRegistry(defaults: defaults)
        registry.add(RegisteredRepository(rootPath: api.path, commonDirectoryPath: api.path + "/.git"))
        let entry = try XCTUnwrap(registry.repositories.first)
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: registry, loader: StubRepositoryLoader(),
            settings: AppSettings(defaults: defaults))
        state.openRegistered(entry.id)
        state.closeIfUnregistered()
        XCTAssertNotNil(state.repository, "still registered: stays open")

        registry.remove(entry.id)
        state.closeIfUnregistered()
        XCTAssertNil(state.repository)
    }
}

/// The two places the remote URL setting applies (#86): S-05's list and the REMOTE group tooltips.
@MainActor
final class RemoteURLSettingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func inspection(_ url: String) -> RepoConfigInspection {
        RepoConfigInspector.inspect(
            ConfigParser.Listing(
                entries: [
                    ConfigEntry(scope: .local, section: "remote", subsection: "origin", variable: "url", value: url)
                ], isPartial: false))
    }

    func testSecurityListFollowsTheSetting() {
        let inspection = inspection("https://alice:s3cr3t@example.com/repo.git")
        XCTAssertEqual(WorktreeSecurityModel.remotesWithCredentials(inspection), ["origin: example.com/repo"])
        let full = WorktreeSecurityModel.remotesWithCredentials(inspection, full: true)
        XCTAssertEqual(full.count, 1)
        XCTAssertTrue(full[0].hasPrefix("origin: https://"))
        XCTAssertFalse(full[0].contains("s3cr3t"))
    }

    func testRemoteTooltipsFollowTheSetting() async {
        let settings = AppSettings(defaults: defaults)
        let listing = WorktreeListing(
            entries: [
                WorktreeListing.Entry(
                    worktree: WorktreeListing.mockup.entries[0].worktree,
                    state: WorktreeListing.mockup.entries[0].state,
                    inspection: inspection("git@github.com:acme/api.git"))
            ],
            isPartial: false)
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(), settings: settings)
        state.showForPreview(listing)
        XCTAssertEqual(state.remoteURLTooltips, ["origin": "github.com/acme/api"])
        settings.showsFullRemoteURLs = true
        XCTAssertEqual(state.remoteURLTooltips, ["origin": "git@github.com:acme/api.git"])
        XCTAssertEqual(
            SidebarPanel.remoteFolderHelp(state.remoteURLTooltips),
            ["remote:origin": "origin — git@github.com:acme/api.git"])
    }
}
