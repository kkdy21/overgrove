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
        RepositoryRegistrar(probe: { kind, _ in Self.answer(kind, root: root) })
    }

    nonisolated private static func answer(_ kind: RegistrationProbe, root: URL) -> Data {
        switch kind {
        case .gitDirectory: Data("\(root.path)/.git\n\(root.path)/.git\nfalse\ntrue\n".utf8)
        case .worktree: Data("\(root.path)\n\(root.path)/.git\nfalse\n".utf8)
        }
    }

    /// Answers `api` as a repository and refuses `plain` (not a repository) and `others` (owned by another user) as
    /// git does; every other folder fails the path check before git runs.
    private func probeRefusing(api: URL) -> RepositoryRegistrar {
        RepositoryRegistrar(probe: { kind, folder in
            switch folder.lastPathComponent {
            case "plain":
                throw GitError.notARepository(detail: MaskedText(masking: "fatal: not a git repository"))
            case "others":
                throw GitError.dubiousOwnership(detail: MaskedText(masking: "fatal: detected dubious ownership"))
            default:
                return Self.answer(kind, root: api)
            }
        })
    }

    /// The setup assistant's checks are stubbed, so presenting it runs no git or gh.
    private func makeState(registrar: RepositoryRegistrar) -> (AppState, RepositoryRegistry) {
        let registry = RepositoryRegistry(defaults: defaults)
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: registry, registrar: registrar,
            loader: StubRepositoryLoader(), gitChecker: StubGitSetupChecker(.missing),
            ghChecker: StubGHAuthChecker(nil))
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
        XCTAssertNil(state.setup.repositoryNotice)
    }

    func testRefusalShowsAnAlertAndRegistersNothing() async throws {
        let folder = try folder("bad\nname")
        let (state, _) = makeState(registrar: probe(root: base))
        await state.addRepository(at: folder)

        XCTAssertEqual(state.registeredRepositories, [])
        XCTAssertNil(state.repository)
        XCTAssertEqual(state.alert?.title, "Couldn’t Add Repository")
        XCTAssertEqual(state.alert?.message, RegistrationError.invalidPath(.controlCharacters).message)
        XCTAssertNil(state.setup.repositoryProblem, "File › Add Repository… keeps the alert")
    }

    /// #679: S-07's sheet hides the window's alert until it closes, so while it is open a refused folder is explained
    /// in its step 1: not a repository, refused for ownership, or any other registration error.
    func testARefusalWhileTheSetupAssistantIsOpenIsShownInItsFirstStep() async throws {
        let api = try repositoryFolder("api")
        let (state, _) = makeState(registrar: probeRefusing(api: api))
        state.setup.present()

        await state.addRepository(at: try folder("plain"))
        XCTAssertEqual(state.setup.repositoryProblem, "This folder is not a Git repository.")
        XCTAssertNil(state.alert, "no alert waiting behind the sheet")

        let ownership = GitError.dubiousOwnership(detail: MaskedText(masking: "")).message
        await state.addRepository(at: try folder("others"))
        XCTAssertEqual(state.setup.repositoryProblem, ownership)

        await state.addRepository(at: try folder("bad\nname"))
        XCTAssertEqual(state.setup.repositoryProblem, RegistrationError.invalidPath(.controlCharacters).message)

        XCTAssertEqual(state.registeredRepositories, [])
        XCTAssertNil(state.repository)
        XCTAssertNil(state.alert)
        // Closing the assistant leaves nothing to pop up afterwards.
        state.setup.dismiss()
        XCTAssertNil(state.alert)
    }

    /// #679: picking another folder in S-07 clears the previous reason, and so does opening the assistant again.
    func testPickingAnotherFolderClearsTheProblem() async throws {
        let api = try repositoryFolder("api")
        let (state, _) = makeState(registrar: probeRefusing(api: api))
        state.setup.present()
        await state.addRepository(at: try folder("plain"))
        XCTAssertNotNil(state.setup.repositoryProblem)

        await state.addRepository(at: api)
        XCTAssertNil(state.setup.repositoryProblem)
        XCTAssertEqual(state.repository?.name, "api")
        XCTAssertNil(state.alert)

        await state.addRepository(at: try folder("plain"))
        XCTAssertNotNil(state.setup.repositoryProblem)
        state.setup.dismiss()
        state.setup.present()
        XCTAssertNil(state.setup.repositoryProblem, "a reopened assistant starts clean")
    }

    /// #679: once S-07 is closed, a refusal goes back to the window's alert.
    func testARefusalAfterTheSetupAssistantClosesShowsTheAlert() async throws {
        let api = try repositoryFolder("api")
        let (state, _) = makeState(registrar: probeRefusing(api: api))
        state.setup.present()
        state.setup.dismiss()
        await state.addRepository(at: try folder("plain"))
        XCTAssertNil(state.setup.repositoryProblem)
        XCTAssertEqual(state.alert?.title, "Couldn’t Add Repository")
        XCTAssertEqual(state.alert?.message, "This folder is not a Git repository.")
    }

    func testNoticeWhenTheRegisteredPathDiffersFromThePickedOne() async throws {
        let api = try repositoryFolder("api")
        let subfolder = try folder("api/src")
        let (state, _) = makeState(registrar: probe(root: api))
        await state.addRepository(at: subfolder)

        XCTAssertEqual(state.alert?.title, "Repository Added")
        XCTAssertEqual(state.alert?.message, "Overgrove added the repository at \(api.path).")
        XCTAssertNil(state.setup.repositoryNotice, "File › Add Repository… keeps the alert")
    }

    /// #702: S-07's sheet hides the window's alert until it closes, so while it is open the note on the added folder is
    /// in its step 1: a repository registered somewhere other than the folder picked, or one in Overgrove already.
    func testANoticeWhileTheSetupAssistantIsOpenIsShownInItsFirstStep() async throws {
        let api = try repositoryFolder("api")
        let subfolder = try folder("api/src")
        let (state, _) = makeState(registrar: probe(root: api))
        state.setup.present()

        await state.addRepository(at: subfolder)
        XCTAssertEqual(state.repository?.name, "api")
        XCTAssertEqual(state.setup.repositoryNotice, "Overgrove added the repository at \(api.path).")
        XCTAssertNil(state.setup.repositoryProblem)
        XCTAssertNil(state.alert, "no alert waiting behind the sheet")

        await state.addRepository(at: api)
        XCTAssertEqual(state.registeredRepositories.count, 1)
        XCTAssertEqual(state.setup.repositoryNotice, "“api” is already in Overgrove, at \(api.path).")
        XCTAssertNil(state.alert)

        // Closing the assistant leaves nothing to pop up afterwards.
        state.setup.dismiss()
        XCTAssertNil(state.alert)
    }

    /// #702: the next pick clears the note (a refusal replaces it), and so does opening the assistant again. Once the
    /// assistant is closed, the note goes back to the alert.
    func testTheNoticeClearsAndGoesBackToTheAlertWithoutTheAssistant() async throws {
        let api = try repositoryFolder("api")
        let subfolder = try folder("api/src")
        let (state, _) = makeState(registrar: probeRefusing(api: api))
        state.setup.present()
        await state.addRepository(at: subfolder)
        XCTAssertNotNil(state.setup.repositoryNotice)

        await state.addRepository(at: try folder("plain"))
        XCTAssertNil(state.setup.repositoryNotice, "a new pick clears the note")
        XCTAssertEqual(state.setup.repositoryProblem, "This folder is not a Git repository.")

        await state.addRepository(at: subfolder)
        XCTAssertNil(state.setup.repositoryProblem)
        XCTAssertNotNil(state.setup.repositoryNotice)
        state.setup.dismiss()
        state.setup.present()
        XCTAssertNil(state.setup.repositoryNotice, "a reopened assistant starts clean")

        state.setup.dismiss()
        await state.addRepository(at: subfolder)
        XCTAssertNil(state.setup.repositoryNotice)
        XCTAssertEqual(state.alert?.title, "Repository Already Added")
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
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: registry, loader: StubRepositoryLoader())
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

    /// Picking the open repository again in the switcher does nothing (#497): no reload resets the search, filters or
    /// selection.
    func testPickingTheOpenRepositoryAgainKeepsItsState() async throws {
        let api = try folder("api")
        let registry = RepositoryRegistry(defaults: defaults)
        registry.add(RegisteredRepository(rootPath: api.path, commonDirectoryPath: api.path + "/.git"))
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: registry, loader: StubRepositoryLoader())
        let apiID = registry.repositories[0].id

        state.openRegistered(apiID)
        let opened = state.repository
        state.searchText = "fix"
        state.sidebarFilter = "feat"
        state.openRegistered(apiID)
        XCTAssertEqual(state.repository, opened)
        XCTAssertEqual(state.searchText, "fix")
        XCTAssertEqual(state.sidebarFilter, "feat")
        XCTAssertEqual(registry.lastSelected, apiID)
    }

    /// Quick Look shows the previous repository's file until something closes it (#496): switching to another
    /// repository or removing the open one does.
    func testSwitchingOrRemovingTheRepositoryClosesQuickLook() async throws {
        let api = try folder("api")
        let web = try folder("web")
        let registry = RepositoryRegistry(defaults: defaults)
        registry.add(RegisteredRepository(rootPath: api.path, commonDirectoryPath: api.path + "/.git"))
        registry.add(RegisteredRepository(rootPath: web.path, commonDirectoryPath: web.path + "/.git"))
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: registry, loader: StubRepositoryLoader())
        let apiID = registry.repositories[0].id
        let webID = registry.repositories[1].id

        state.openRegistered(webID)
        state.quickLookURL = web.appendingPathComponent("README.md")
        state.openRegistered(apiID)
        XCTAssertNil(state.quickLookURL, "switching closes the panel")

        state.quickLookURL = api.appendingPathComponent("README.md")
        state.removeRepository(apiID)
        XCTAssertNil(state.quickLookURL, "removing the open repository closes the panel")
    }

    func testRestoreOpensTheLastSelectedRepositoryOnce() throws {
        let api = try folder("api")
        let web = try folder("web")
        let registry = RepositoryRegistry(defaults: defaults)
        registry.add(RegisteredRepository(rootPath: api.path, commonDirectoryPath: api.path + "/.git"))
        registry.add(RegisteredRepository(rootPath: web.path, commonDirectoryPath: web.path + "/.git"))
        registry.lastSelected = registry.repositories[1].id

        let relaunched = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader())
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
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: registry, loader: StubRepositoryLoader())

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
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: registry, loader: StubRepositoryLoader())

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
