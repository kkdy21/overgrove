import Foundation
import XCTest

@testable import Overgrove

/// `AppState` registration flows (#84): add, dedupe, switch, remove, restore, and the alerts.
@MainActor
final class AppStateRegistrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var base: URL!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let temporary = try XCTUnwrap(PathValidator.canonical(FileManager.default.temporaryDirectory))
        base = temporary.appendingPathComponent("overgrove-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: base)
    }

    /// A folder standing in for a repository root (registration itself is covered by `RepositoryRegistrarTests`).
    private func folder(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A folder with a `.git` directory, enough for the registrar's file-system cross-check.
    private func repositoryFolder(_ name: String) throws -> URL {
        let url = try folder(name)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return url
    }

    /// Answers the probes as git would for a repository at `root`, whichever folder inside it is picked.
    private func probe(root: URL) -> RepositoryRegistrar {
        RepositoryRegistrar(probe: { kind, _ in
            switch kind {
            case .gitDirectory: Data("\(root.path)/.git\n\(root.path)/.git\nfalse\ntrue\n".utf8)
            case .worktree: Data("\(root.path)\n\(root.path)/.git\nfalse\n".utf8)
            }
        })
    }

    private func makeState(registrar: RepositoryRegistrar) -> (AppState, RepositoryRegistry) {
        let registry = RepositoryRegistry(defaults: defaults)
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: registry, registrar: registrar)
        return (state, registry)
    }

    func testAddRegistersOpensAndRemembersTheRepository() async throws {
        let api = try repositoryFolder("api")
        let (state, registry) = makeState(registrar: probe(root: api))
        await state.addRepository(at: api)

        XCTAssertEqual(state.registeredRepositories.map(\.name), ["api"])
        XCTAssertEqual(state.repository?.name, "api")
        XCTAssertEqual(state.repository?.repository.rootURL?.path, api.path)
        XCTAssertEqual(registry.lastSelected, state.repository?.repository.id)
        XCTAssertNil(state.alert)
        XCTAssertFalse(state.isAddingRepository)
    }

    func testAddingTheSameRepositoryAgainOpensItWithoutDuplicating() async throws {
        let api = try repositoryFolder("api")
        let subfolder = try folder("api/src")
        let (state, _) = makeState(registrar: probe(root: api))
        await state.addRepository(at: api)
        await state.addRepository(at: subfolder)

        XCTAssertEqual(state.registeredRepositories.count, 1)
        XCTAssertEqual(state.repository?.name, "api")
        XCTAssertEqual(state.alert?.title, "Repository Already Added")
        XCTAssertEqual(state.alert?.message, "“api” is already in Overgrove, at \(api.path).")
    }

    func testRefusalShowsAnAlertAndRegistersNothing() async throws {
        let folder = try folder("bad\nname")
        let (state, _) = makeState(registrar: probe(root: base))
        await state.addRepository(at: folder)

        XCTAssertEqual(state.registeredRepositories, [])
        XCTAssertNil(state.repository)
        XCTAssertEqual(state.alert?.title, "Couldn’t Add Repository")
        XCTAssertEqual(state.alert?.message, RegistrationError.invalidPath(.controlCharacters).message)
    }

    func testNoticeWhenTheRegisteredPathDiffersFromThePickedOne() async throws {
        let api = try repositoryFolder("api")
        let subfolder = try folder("api/src")
        let (state, _) = makeState(registrar: probe(root: api))
        await state.addRepository(at: subfolder)

        XCTAssertEqual(state.alert?.title, "Repository Added")
        XCTAssertEqual(state.alert?.message, "Overgrove added the repository at \(api.path).")
    }

    /// L-3 of the #84 security review: a bidi override in a folder name is shown escaped, not obeyed.
    func testNamesWithFormatCharactersAreShownEscaped() async throws {
        let tricky = try repositoryFolder("evil\u{202E}txt.app")
        let (state, _) = makeState(registrar: probe(root: tricky))
        await state.addRepository(at: tricky)

        XCTAssertEqual(state.repository?.name, "evil\\u{202E}txt.app")
        XCTAssertEqual(state.registeredRepositories.first?.name, "evil\\u{202E}txt.app")
        XCTAssertEqual(state.registeredRepositories.first?.rootPath, tricky.path, "the stored path is unchanged")
    }

    func testSwitchingAndRemoving() async throws {
        let api = try folder("api")
        let web = try folder("web")
        let registry = RepositoryRegistry(defaults: defaults)
        registry.add(RegisteredRepository(rootPath: api.path, commonDirectoryPath: api.path + "/.git"))
        registry.add(RegisteredRepository(rootPath: web.path, commonDirectoryPath: web.path + "/.git"))
        let state = AppState(layoutStore: PanelLayoutStore(defaults: defaults), registry: registry)
        let apiID = registry.repositories[0].id
        let webID = registry.repositories[1].id

        state.openRegistered(webID)
        XCTAssertEqual(state.repository?.name, "web")
        state.openRegistered(apiID)
        XCTAssertEqual(state.repository?.name, "api")

        // Removing another repository leaves this window alone.
        state.removeRepository(webID)
        XCTAssertEqual(state.repository?.name, "api")
        // Removing the open one closes it; the folder stays.
        state.searchText = "fix"
        state.removeRepository(apiID)
        XCTAssertNil(state.repository)
        XCTAssertEqual(state.searchText, "")
        XCTAssertEqual(state.registeredRepositories, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: api.path))
    }

    func testRestoreOpensTheLastSelectedRepositoryOnce() throws {
        let api = try folder("api")
        let web = try folder("web")
        let registry = RepositoryRegistry(defaults: defaults)
        registry.add(RegisteredRepository(rootPath: api.path, commonDirectoryPath: api.path + "/.git"))
        registry.add(RegisteredRepository(rootPath: web.path, commonDirectoryPath: web.path + "/.git"))
        registry.lastSelected = registry.repositories[1].id

        let relaunched = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults))
        relaunched.restoreLastSelected()
        XCTAssertEqual(relaunched.repository?.name, "web")

        relaunched.openRegistered(registry.repositories[0].id)
        relaunched.restoreLastSelected()
        XCTAssertEqual(relaunched.repository?.name, "api", "restoring does not replace an open repository")
    }

    func testMissingFolderIsNotOpened() throws {
        let gone = base.appendingPathComponent("gone", isDirectory: true)
        let registry = RepositoryRegistry(defaults: defaults)
        registry.add(RegisteredRepository(rootPath: gone.path, commonDirectoryPath: gone.path + "/.git"))
        registry.lastSelected = registry.repositories[0].id
        let state = AppState(layoutStore: PanelLayoutStore(defaults: defaults), registry: registry)

        state.restoreLastSelected()
        XCTAssertNil(state.repository)
        XCTAssertNil(state.alert, "restoring at launch stays quiet")

        state.openRegistered(registry.repositories[0].id)
        XCTAssertNil(state.repository)
        XCTAssertEqual(state.alert?.title, "Repository Not Found")
    }

    /// #222: a bare repository is checked at its git directory, since it has no root folder.
    func testBareRepositoryOpensFromItsGitDirectory() throws {
        let bare = try folder("api.git")
        let registry = RepositoryRegistry(defaults: defaults)
        registry.add(RegisteredRepository(rootPath: nil, commonDirectoryPath: bare.path))
        let state = AppState(layoutStore: PanelLayoutStore(defaults: defaults), registry: registry)

        state.openRegistered(registry.repositories[0].id)
        XCTAssertNil(state.alert)
        XCTAssertNil(state.repository?.repository.rootURL)
        XCTAssertEqual(state.repository?.repository.commonGitDirectoryURL.path, bare.path)

        try FileManager.default.removeItem(at: bare)
        let relaunched = AppState(layoutStore: PanelLayoutStore(defaults: defaults), registry: registry)
        relaunched.openRegistered(registry.repositories[0].id)
        XCTAssertNil(relaunched.repository)
        XCTAssertEqual(relaunched.alert?.title, "Repository Not Found")
    }

    /// T14: a registered folder later replaced by a symbolic link to somewhere else is not opened.
    func testFolderReplacedByASymlinkIsNotOpened() throws {
        let api = try folder("api")
        let elsewhere = try folder("elsewhere")
        let registry = RepositoryRegistry(defaults: defaults)
        registry.add(RegisteredRepository(rootPath: api.path, commonDirectoryPath: api.path + "/.git"))
        try FileManager.default.removeItem(at: api)
        try FileManager.default.createSymbolicLink(at: api, withDestinationURL: elsewhere)
        let state = AppState(layoutStore: PanelLayoutStore(defaults: defaults), registry: registry)

        state.openRegistered(registry.repositories[0].id)
        XCTAssertNil(state.repository)
        XCTAssertEqual(state.alert?.title, "Repository Not Found")
    }

    func testMenuModelChecksTheOpenRepositoryAndOffersToRemoveIt() {
        let repositories = [
            RegisteredRepository(rootPath: "/tmp/dev/api", commonDirectoryPath: "/tmp/dev/api/.git"),
            RegisteredRepository(rootPath: "/tmp/dev/web", commonDirectoryPath: "/tmp/dev/web/.git"),
        ]
        let open = RepositoryMenuModel(repositories: repositories, openID: repositories[1].id)
        XCTAssertEqual(open.items.map(\.name), ["api", "web"])
        XCTAssertEqual(open.items.map(\.isOpen), [false, true])
        XCTAssertEqual(open.items[0].path, "/tmp/dev/api")
        XCTAssertEqual(open.removeTitle, "Remove “web” from Overgrove")

        let none = RepositoryMenuModel(repositories: repositories, openID: nil)
        XCTAssertNil(none.removeTitle)
        XCTAssertEqual(RepositoryMenuModel(repositories: [], openID: nil).items, [])
    }

    func testPickerAcceptsOneExistingFolderOnly() {
        let panel = RepositoryPicker.makePanel()
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.canCreateDirectories)
        XCTAssertEqual(panel.prompt, "Add")
    }
}
