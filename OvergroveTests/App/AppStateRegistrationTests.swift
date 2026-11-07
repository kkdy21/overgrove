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

    /// Answers the probe as git would for a repository at `root`, whichever folder inside it is picked.
    private func probe(root: URL) -> RepositoryRegistrar {
        RepositoryRegistrar(probe: { folder in
            Data("\(folder.path)\n\(root.path)/.git\nfalse\n".utf8)
        })
    }

    private func makeState(registrar: RepositoryRegistrar) -> (AppState, RepositoryRegistry) {
        let registry = RepositoryRegistry(defaults: defaults)
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: registry, registrar: registrar)
        return (state, registry)
    }

    func testAddRegistersOpensAndRemembersTheRepository() async throws {
        let api = try folder("api")
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
        let api = try folder("api")
        let worktree = try folder("api-wt")
        let (state, _) = makeState(registrar: probe(root: api))
        await state.addRepository(at: api)
        await state.addRepository(at: worktree)

        XCTAssertEqual(state.registeredRepositories.count, 1)
        XCTAssertEqual(state.repository?.name, "api")
        XCTAssertEqual(state.alert?.title, "Repository Already Added")
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
        let api = try folder("api")
        let subfolder = try folder("api/src")
        let (state, _) = makeState(
            registrar: RepositoryRegistrar(probe: { _ in
                Data("\(api.path)\n\(api.path)/.git\nfalse\n".utf8)
            }))
        await state.addRepository(at: subfolder)

        XCTAssertEqual(state.alert?.title, "Repository Added")
        XCTAssertEqual(state.alert?.message, "Overgrove added the repository at \(api.path).")
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
