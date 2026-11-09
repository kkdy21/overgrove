import Foundation
import XCTest

@testable import Overgrove

/// Answers git checks with a fixed status and counts them.
final class StubGitSetupChecker: GitSetupChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var status: GitSetupStatus
    private var calls = 0

    init(_ status: GitSetupStatus) { self.status = status }

    var count: Int { lock.withLock { calls } }
    func set(_ new: GitSetupStatus) { lock.withLock { status = new } }

    func check() async -> GitSetupStatus {
        lock.withLock {
            calls += 1
            return status
        }
    }
}

/// Answers gh checks with a fixed status and counts them.
final class StubGHAuthChecker: GHAuthChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var status: GHAuthStatus?
    private var calls = 0

    init(_ status: GHAuthStatus?) { self.status = status }

    var count: Int { lock.withLock { calls } }
    func set(_ new: GHAuthStatus?) { lock.withLock { status = new } }

    func authStatus() async -> GHAuthStatus? {
        lock.withLock {
            calls += 1
            return status
        }
    }
}

/// GitHub CLI wording shared by S-07 and the issues panel (#85, #83).
final class GHStatusGuidanceTests: XCTestCase {
    func testEveryState() {
        let loggedIn = GHStatusGuidance(status: .loggedIn(login: "mina-dev"))
        XCTAssertEqual(loggedIn.title, "Logged in as @mina-dev")
        XCTAssertTrue(loggedIn.isOK)
        XCTAssertNil(loggedIn.command)

        let notLoggedIn = GHStatusGuidance(status: .notLoggedIn)
        XCTAssertEqual(notLoggedIn.title, "Not logged in")
        XCTAssertEqual(notLoggedIn.message, "Run this in Terminal, then check again:")
        XCTAssertEqual(notLoggedIn.command, "gh auth login")
        XCTAssertFalse(notLoggedIn.isOK)

        let notInstalled = GHStatusGuidance(status: .notInstalled)
        XCTAssertEqual(notInstalled.command, "brew install gh")
        XCTAssertFalse(notInstalled.isOK)

        let failed = GHStatusGuidance(checkFailed: "gh exited with status 1")
        XCTAssertEqual(failed.title, "Couldn't check GitHub CLI")
        XCTAssertEqual(failed.message, "gh exited with status 1")
        XCTAssertNil(failed.command, "no command when the state is unknown")
    }

    /// #476: S-07 reads the same report as the status bar. A login only on another host counts as set up, and says
    /// where; github.com's own login keeps the usual wording.
    func testReportWithLoginsOnOtherHosts() throws {
        let ghe = try XCTUnwrap(RemoteHost("ghe.example"))
        let other = try XCTUnwrap(RemoteHost("code.example.org"))
        let github = GHStatusGuidance(
            report: GHAuthReport(
                status: .loggedIn(login: "mina-dev"), hosts: [GitHubRepository.publicHost, ghe],
                accounts: [ghe: GHAccount(host: ghe, login: "me", otherCount: 0)]))
        XCTAssertEqual(github, GHStatusGuidance(status: .loggedIn(login: "mina-dev")))

        let gheOnly = GHStatusGuidance(
            report: GHAuthReport(
                status: .notLoggedIn, hosts: [ghe], accounts: [ghe: GHAccount(host: ghe, login: "me", otherCount: 1)]))
        XCTAssertTrue(gheOnly.isOK)
        XCTAssertEqual(gheOnly.title, "Logged in to ghe.example as @me")
        XCTAssertEqual(
            gheOnly.message,
            "Not logged in to github.com. Issues appear for repositories on the hosts gh is logged in to.")
        XCTAssertNil(gheOnly.command)

        let two = GHStatusGuidance(report: GHAuthReport(status: .notLoggedIn, hosts: [ghe, other]))
        XCTAssertTrue(two.isOK)
        XCTAssertEqual(two.title, "Logged in to code.example.org and 1 more host", "sorted; no account to name")

        // No working login anywhere (the report lists only working hosts, #467): the usual guidance.
        XCTAssertEqual(
            GHStatusGuidance(report: GHAuthReport(status: .notLoggedIn, hosts: [])),
            GHStatusGuidance(status: .notLoggedIn))
        XCTAssertEqual(
            GHStatusGuidance(report: GHAuthReport(status: .notInstalled, hosts: [])),
            GHStatusGuidance(status: .notInstalled))
    }

    /// The login comes from gh's JSON; control characters are escaped before display.
    func testLoginIsEscaped() {
        let guidance = GHStatusGuidance(status: .loggedIn(login: "evil\u{202E}\n"))
        XCTAssertFalse(guidance.title.contains("\u{202E}"))
        XCTAssertFalse(guidance.title.contains("\n"))
    }
}

/// The git step's check (#85): the same discovery every query uses.
final class GitSetupCheckerTests: XCTestCase {
    func testErrorsMapToSteps() {
        XCTAssertEqual(LiveGitSetupChecker.status(for: .executableNotFound(path: "/usr/bin/git")), .missing)
        let old = GitVersion(major: 2, minor: 30, patch: 1)
        XCTAssertEqual(LiveGitSetupChecker.status(for: .unsupportedVersion(found: old)), .unsupported(found: old))
        guard case .failed = LiveGitSetupChecker.status(for: .launchFailed(errno: 2)) else {
            return XCTFail("other errors are a failed check")
        }
    }

    func testLiveCheckerReportsTheDiscoveredGit() async throws {
        let environment = try await GitEnvironment.discoverForTesting()
        let checker = LiveGitSetupChecker(client: { GitClient(environment: environment) })
        let status = await checker.check()
        XCTAssertEqual(status, .ready(version: environment.version, path: environment.executable.path))

        let missing = LiveGitSetupChecker(client: { throw GitError.executableNotFound(path: "/usr/bin/git") })
        let missingStatus = await missing.check()
        XCTAssertEqual(missingStatus, .missing)
    }
}

/// `SetupAssistantState` and its first-run opening (S-07, #85).
@MainActor
final class SetupAssistantStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let ready = GitSetupStatus.ready(version: GitVersion(major: 2, minor: 50, patch: 1), path: "/usr/bin/git")

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testPresentChecksGitAndGitHub() async {
        let git = StubGitSetupChecker(ready)
        let gh = StubGHAuthChecker(.notLoggedIn)
        let setup = SetupAssistantState(gitChecker: git, ghChecker: gh)
        setup.present()
        XCTAssertTrue(setup.isPresented)
        XCTAssertNil(setup.git, "checking")
        XCTAssertEqual(setup.gitHub, .checking)
        await setup.gitTask?.value
        await setup.gitHubTask?.value
        XCTAssertEqual(setup.git, ready)
        XCTAssertEqual(setup.gitHub, .done(GHStatusGuidance(status: .notLoggedIn)))

        // Check Again after `gh auth login`.
        gh.set(.loggedIn(login: "mina-dev"))
        setup.checkGitHub()
        await setup.gitHubTask?.value
        XCTAssertEqual(setup.gitHub, .done(GHStatusGuidance(status: .loggedIn(login: "mina-dev"))))
        XCTAssertEqual(gh.count, 2)

        setup.dismiss()
        XCTAssertFalse(setup.isPresented)
    }

    /// #106, ADR-0019 §4: a refused Settings choice offers Use Default, which forgets the choice and checks again.
    func testUseDefaultForgetsTheChoiceAndChecksAgain() async {
        let rejected = GitSetupStatus.chosenRejected(
            path: "/opt/homebrew/bin/git", reason: "No file exists at that path.")
        let git = StubGitSetupChecker(rejected)
        var forgotten = 0
        let setup = SetupAssistantState(
            gitChecker: git, ghChecker: StubGHAuthChecker(nil),
            useDefaultGit: {
                forgotten += 1
                git.set(self.ready)
            })
        XCTAssertTrue(setup.canUseDefaultGit)
        setup.checkGit()
        await setup.gitTask?.value
        XCTAssertEqual(setup.git, rejected)
        XCTAssertFalse(setup.canFinish(hasRepository: true))

        setup.useDefaultGit()
        await setup.gitTask?.value
        XCTAssertEqual(forgotten, 1)
        XCTAssertEqual(setup.git, ready)

        XCTAssertFalse(SetupAssistantState(gitChecker: git, ghChecker: StubGHAuthChecker(nil)).canUseDefaultGit)
    }

    func testLiveCheckerMapsARefusedChoice() {
        XCTAssertEqual(
            LiveGitSetupChecker.status(for: .chosenExecutableRejected(path: "/x/git", reason: "Not executable.")),
            .chosenRejected(path: "/x/git", reason: "Not executable."))
    }

    /// #476: the assistant asks for the whole report, so a GHE-only login is shown as set up.
    func testTheAssistantUsesTheWholeReport() async throws {
        let ghe = try XCTUnwrap(RemoteHost("ghe.example"))
        let report = GHAuthReport(
            status: .notLoggedIn, hosts: [ghe], accounts: [ghe: GHAccount(host: ghe, login: "me", otherCount: 0)])
        let setup = SetupAssistantState(
            gitChecker: StubGitSetupChecker(ready), ghChecker: QueuedGHAuthReporter([report]))
        setup.checkGitHub()
        await setup.gitHubTask?.value
        XCTAssertEqual(setup.gitHub, .done(GHStatusGuidance(report: report)))
        guard case .done(let guidance) = setup.gitHub else { return XCTFail("checked") }
        XCTAssertTrue(guidance.isOK)
    }

    func testGitHubCheckFailureIsShownAsUnknown() async {
        let setup = SetupAssistantState(gitChecker: StubGitSetupChecker(ready), ghChecker: StubGHAuthChecker(nil))
        setup.checkGitHub()
        await setup.gitHubTask?.value
        XCTAssertEqual(setup.gitHub, .done(GHStatusGuidance(checkFailed: nil)))
    }

    /// `Open Repository` needs a repository and a usable git; GitHub is optional.
    func testFinishNeedsARepositoryAndGit() async {
        let git = StubGitSetupChecker(.missing)
        let setup = SetupAssistantState(gitChecker: git, ghChecker: StubGHAuthChecker(.notInstalled))
        setup.checkGit()
        await setup.gitTask?.value
        XCTAssertFalse(setup.canFinish(hasRepository: true), "git missing")

        git.set(.unsupported(found: GitVersion(major: 2, minor: 30, patch: 0)))
        setup.checkGit()
        await setup.gitTask?.value
        XCTAssertFalse(setup.canFinish(hasRepository: true), "git too old")

        git.set(ready)
        setup.checkGit()
        await setup.gitTask?.value
        XCTAssertFalse(setup.canFinish(hasRepository: false), "no repository yet")
        XCTAssertTrue(setup.canFinish(hasRepository: true), "GitHub not needed")
    }

    func testFirstRunOpensTheAssistant() async {
        let git = StubGitSetupChecker(ready)
        let gh = StubGHAuthChecker(.loggedIn(login: "mina-dev"))
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(), gitChecker: git, ghChecker: gh)
        state.restoreLastSelected()
        XCTAssertTrue(state.setup.isPresented, "nothing registered: first run")
        await state.setup.gitTask?.value
        await state.setup.gitHubTask?.value
        XCTAssertEqual(git.count, 1)
        XCTAssertEqual(gh.count, 1)
    }

    func testLaterRunsDoNotOpenIt() throws {
        let registry = RepositoryRegistry(defaults: defaults)
        registry.add(RegisteredRepository(rootPath: "/tmp/dev/gone", commonDirectoryPath: "/tmp/dev/gone/.git"))
        let gh = StubGHAuthChecker(nil)
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: registry, loader: StubRepositoryLoader(),
            gitChecker: StubGitSetupChecker(ready), ghChecker: gh)
        state.restoreLastSelected()
        XCTAssertFalse(state.setup.isPresented)
        XCTAssertEqual(gh.count, 0, "no gh check without the assistant")
    }
}
