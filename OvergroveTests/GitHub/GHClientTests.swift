import Foundation
import XCTest

@testable import Overgrove

private let loggedInJSON = """
    {"hosts":{"github.com":[{"active":true,"gitProtocol":"https","host":"github.com","login":"octo-cat",\
    "scopes":"repo","state":"success","tokenSource":"keyring"}]}}
    """

private let issuesJSON = """
    [{"number":12,"title":"Add parser","state":"OPEN","labels":[{"name":"area:parser","color":"0e8a16"}],\
    "assignees":[{"login":"octo-cat"}],"updatedAt":"2026-11-05T10:00:00Z",\
    "url":"https://github.com/kkdy21/overgrove/issues/12"}]
    """

private let pullRequestsJSON = """
    [{"baseRefName":"main","headRefName":"feat/1-x","headRepository":{"id":"R_1","name":"overgrove"},\
    "headRepositoryOwner":{"id":"U_1","login":"kkdy21"},"isCrossRepository":false,"isDraft":false,"mergedAt":null,\
    "number":1,"reviewDecision":"","state":"OPEN","title":"feat: x","updatedAt":"2026-11-08T03:14:08Z",\
    "url":"https://github.com/kkdy21/overgrove/pull/1"}]
    """

private let repository = GitHubRepository(owner: "kkdy21", name: "overgrove")!

/// gh allowlist arguments and repository validation (git-command-catalog.md §5, ADR-0004).
final class GHCommandTests: XCTestCase {
    private let allCommands: [GHCommand] = [
        .version, .authStatus, .issueList(repo: repository), .prList(repo: repository),
    ]

    func testArgumentSnapshot() {
        XCTAssertEqual(GHCommand.version.arguments, ["--version"])
        XCTAssertEqual(
            GHCommand.authStatus.arguments, ["auth", "status", "--json", "hosts"])
        // ADR-0025 §3: another host is chosen by `--repo HOST/OWNER/NAME` only.
        let ghe = GitHubRepository(owner: "team", name: "app", host: RemoteHost("ghe.example")!)!
        XCTAssertEqual(GHCommand.issueList(repo: ghe).arguments[2...3], ["--repo", "ghe.example/team/app"])
        XCTAssertEqual(GHCommand.prList(repo: ghe).arguments[2...3], ["--repo", "ghe.example/team/app"])
        XCTAssertEqual(
            GHCommand.issueList(repo: repository).arguments,
            [
                "issue", "list", "--repo", "github.com/kkdy21/overgrove", "--state", "open", "--limit", "200", "--json",
                "number,title,state,labels,assignees,updatedAt,url",
            ]
        )
        // ADR-0023 §1: these thirteen fields only; no body, comments, files, reviews, or CI status.
        XCTAssertEqual(
            GHCommand.prList(repo: repository).arguments,
            [
                "pr", "list", "--repo", "github.com/kkdy21/overgrove", "--state", "all", "--limit", "200", "--json",
                "number,title,state,isDraft,isCrossRepository,headRefName,headRepositoryOwner,headRepository,"
                    + "baseRefName,reviewDecision,mergedAt,updatedAt,url",
            ]
        )
    }

    /// SEC-T11-05: no command can ask gh for a token, and only allowlisted subcommands exist (T13).
    func testSECT11_05_NoCommandRequestsATokenOrWrites() {
        let allowedSubcommands: Set<[String]> = [
            ["--version"], ["auth", "status"], ["issue", "list"], ["pr", "list"],
        ]
        for command in allCommands {
            let arguments = command.arguments
            let head = arguments.first == "--version" ? ["--version"] : Array(arguments.prefix(2))
            XCTAssertTrue(allowedSubcommands.contains(head), "\(command): \(head)")
            for argument in arguments {
                XCTAssertFalse(argument.lowercased().contains("token"), "\(command): \(argument)")
            }
        }
    }

    func testRepositoryScopedCommandsAlwaysNameTheRepository() {
        for command in [GHCommand.issueList(repo: repository), .prList(repo: repository)] {
            let arguments = command.arguments
            let index = try? XCTUnwrap(arguments.firstIndex(of: "--repo"))
            XCTAssertEqual(index.map { arguments[$0 + 1] }, "github.com/kkdy21/overgrove", "\(command)")
        }
    }

    func testValidRepositories() {
        for (owner, name) in [
            ("kkdy21", "overgrove"), ("a", "b"), ("Org-Name", "repo.name_with-dash"),
            (String(repeating: "a", count: 39), String(repeating: "b", count: 100)), ("x", ".github"),
            // Allowed by the NAME rule; harmless because the `--repo` value starts with the host, never `-`.
            ("owner", "--json"),
        ] {
            XCTAssertNotNil(GitHubRepository(owner: owner, name: name), "\(owner)/\(name)")
        }
        XCTAssertFalse(GitHubRepository(owner: "owner", name: "--json")!.slug.hasPrefix("-"))
        XCTAssertEqual(repository.slug, "kkdy21/overgrove")
    }

    func testRejectedRepositories() {
        for (owner, name) in [
            ("", "repo"), ("owner", ""), ("-owner", "repo"), ("own_er", "repo"), ("own.er", "repo"),
            (String(repeating: "a", count: 40), "repo"), ("owner", String(repeating: "b", count: 101)),
            ("owner", "re po"), ("owner", "re/po"), ("owner", "."), ("owner", ".."), ("ówner", "repo"),
            ("owner", "repo\n"), ("owner", "repo;rm"),
        ] {
            XCTAssertNil(GitHubRepository(owner: owner, name: name), "\(owner)/\(name)")
        }
    }
}

/// GHClient: executable lookup, hardened environment, neutral directory, and result mapping.
final class GHClientTests: XCTestCase {
    private var executables: TestExecutables!
    private var neutral: URL!

    private let hostileParent: [String: String] = [
        "GH_TOKEN": "ghp_" + String(repeating: "a", count: 36),
        "GITHUB_TOKEN": "ghp_" + String(repeating: "b", count: 36),
        "GH_ENTERPRISE_TOKEN": "x",
        "GITHUB_ENTERPRISE_TOKEN": "x",
        "GH_HOST": "evil.example",
        "GH_REPO": "evil/repo",
        "GH_CONFIG_DIR": "/evil/gh",
        "GH_DEBUG": "api",
        "GH_FORCE_TTY": "1",
        "BROWSER": "/evil/browser",
        "GH_BROWSER": "/evil/browser",
        "EDITOR": "/evil/editor",
        "GH_EDITOR": "/evil/editor",
        "GIT_DIR": "/evil/.git",
        "GIT_CONFIG_PARAMETERS": "'core.fsmonitor=touch /tmp/pwned'",
        "DYLD_INSERT_LIBRARIES": "/evil/lib.dylib",
        "HTTPS_PROXY": "http://evil.example:8080",
        "PATH": "/evil/bin:/usr/bin",
        "HOME": "/Users/example",
        "USER": "example",
        "TMPDIR": "/tmp/example/",
        "SSH_AUTH_SOCK": "/tmp/agent.sock",
    ]

    override func setUpWithError() throws {
        executables = try TestExecutables()
        neutral = executables.directory.appendingPathComponent("neutral", isDirectory: true)
        try FileManager.default.createDirectory(at: neutral, withIntermediateDirectories: true)
    }

    override func tearDown() {
        executables.remove()
    }

    private func client(
        _ fake: FakeGH?,
        parent: [String: String]? = nil,
        limits: ProcessLimits = .gh
    ) -> GHClient {
        GHClient(
            parentEnvironment: parent ?? hostileParent,
            neutralDirectory: neutral,
            executableCandidates: fake.map { [$0.executable] } ?? [],
            limits: limits
        )
    }

    /// `pwd -P` prints `/private/var/...`; Foundation's resolution drops `/private`, so normalize both sides.
    private func assertRanInNeutralDirectory(_ fake: FakeGH, file: StaticString = #filePath, line: UInt = #line) {
        let recorded = fake.recordedDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(recorded, neutral.resolvingSymlinksInPath().path, file: file, line: line)
    }

    // MARK: Environment (SEC-T10-03)

    func testSECT10_03_EnvironmentIsExactlyTheAllowlist() {
        let environment = GHClient.environment(parent: hostileParent)
        XCTAssertEqual(
            environment,
            [
                "HOME": "/Users/example", "USER": "example", "TMPDIR": "/tmp/example/",
                "PATH": GitEnvironment.path,
                "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1",
                "GH_TELEMETRY": "0", "DO_NOT_TRACK": "1", "GH_SPINNER_DISABLED": "1", "NO_COLOR": "1",
                "GH_PAGER": "cat", "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0",
            ]
        )
    }

    func testSECT10_03_MissingParentVariablesAreOmitted() {
        let environment = GHClient.environment(parent: [:])
        XCTAssertNil(environment["HOME"])
        XCTAssertEqual(environment["GH_TELEMETRY"], "0")
    }

    func testSECT10_03_ChildSeesOnlyTheAllowlist() async throws {
        let fake = try executables.fakeGH(stdout: loggedInJSON)
        _ = try await client(fake).authStatus()
        let recorded = try XCTUnwrap(fake.recordedEnvironment)
        XCTAssertEqual(recorded, GHClient.environment(parent: hostileParent))
        XCTAssertNil(recorded["GH_TOKEN"])
        XCTAssertNil(recorded["GITHUB_TOKEN"])
    }

    // MARK: Executable lookup

    func testExecutableCandidatesAreFixed() {
        XCTAssertEqual(
            GHClient.defaultExecutableCandidates.map(\.path), ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"])
    }

    func testLookupTakesTheFirstExecutableCandidate() throws {
        let first = try executables.fakeGH(stdout: "")
        let second = try executables.fakeGH(stdout: "")
        let missing = executables.directory.appendingPathComponent("missing/gh")
        let notExecutable = executables.directory.appendingPathComponent("plain-gh")
        try Data().write(to: notExecutable)
        let directory = executables.directory.appendingPathComponent("dir-gh", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let found = GHClient.locateExecutable(
            candidates: [missing, notExecutable, directory, first.executable, second.executable])
        XCTAssertEqual(found, first.executable)
        XCTAssertNil(GHClient.locateExecutable(candidates: [missing, notExecutable, directory]))
    }

    func testLookupFollowsSymbolicLinksAndSkipsBrokenOnes() throws {
        let fake = try executables.fakeGH(stdout: "")
        let link = executables.directory.appendingPathComponent("link-gh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fake.executable)
        let broken = executables.directory.appendingPathComponent("broken-gh")
        try FileManager.default.createSymbolicLink(
            at: broken, withDestinationURL: executables.directory.appendingPathComponent("nowhere"))
        XCTAssertEqual(GHClient.locateExecutable(candidates: [broken, link]), link)
    }

    func testMissingExecutableIsNotInstalled() async throws {
        let status = try await client(nil).authStatus()
        XCTAssertEqual(status, .notInstalled)
        do {
            _ = try await client(nil).issues(in: repository)
            XCTFail("expected notInstalled")
        } catch let error as GHError {
            XCTAssertEqual(error, .notInstalled)
            XCTAssertEqual(error.suggestedCommand, "brew install gh")
        }
    }

    // MARK: auth status

    func testLoggedIn() async throws {
        let fake = try executables.fakeGH(stdout: loggedInJSON)
        let status = try await client(fake).authStatus()
        XCTAssertEqual(status, .loggedIn(login: "octo-cat"))
        XCTAssertEqual(fake.recordedArguments, GHCommand.authStatus.arguments)
    }

    func testDefaultNeutralDirectoryIsAppOwnedUnderTemporaryDirectory() {
        let directory = GHClient.defaultNeutralDirectory
        XCTAssertEqual(
            directory.deletingLastPathComponent().standardizedFileURL,
            FileManager.default.temporaryDirectory.standardizedFileURL)
        XCTAssertEqual(directory.lastPathComponent, "io.github.kkdy21.overgrove.gh-neutral")
    }

    func testNeutralDirectoryIsCreatedPrivateOnFirstUse() async throws {
        neutral = executables.directory.appendingPathComponent("not-yet/neutral", isDirectory: true)
        let fake = try executables.fakeGH(stdout: loggedInJSON)
        _ = try await client(fake).authStatus()
        let attributes = try FileManager.default.attributesOfItem(atPath: neutral.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        assertRanInNeutralDirectory(fake)
    }

    func testRunsInTheNeutralDirectory() async throws {
        let fake = try executables.fakeGH(stdout: loggedInJSON)
        _ = try await client(fake).authStatus()
        assertRanInNeutralDirectory(fake)
    }

    func testLoggedOutExitsZeroWithEmptyHosts() async throws {
        let fake = try executables.fakeGH(
            stdout: #"{"hosts":{}}"#,
            stderr: "You are not logged into any GitHub hosts. To log in, run: gh auth login\n"
        )
        let status = try await client(fake).authStatus()
        XCTAssertEqual(status, .notLoggedIn)
    }

    func testBrokenTokenIsNotLoggedIn() async throws {
        let json = #"{"hosts":{"github.com":[{"active":true,"login":"octo-cat","state":"error"}]}}"#
        let status = try await client(try executables.fakeGH(stdout: json)).authStatus()
        XCTAssertEqual(status, .notLoggedIn)
    }

    func testJSONWithNonZeroExitIsStillParsed() async throws {
        let fake = try executables.fakeGH(stdout: #"{"hosts":{}}"#, exitCode: 1)
        let status = try await client(fake).authStatus()
        XCTAssertEqual(status, .notLoggedIn)
    }

    func testOldGHWithoutJSONFlagIsNonZeroExit() async throws {
        let fake = try executables.fakeGH(stdout: "", stderr: "unknown flag: --json\n", exitCode: 1)
        do {
            _ = try await client(fake).authStatus()
            XCTFail("expected nonZeroExit")
        } catch let error as GHError {
            guard case .nonZeroExit(let code, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 1)
            XCTAssertEqual(detail.summary, "unknown flag: --json")
            XCTAssertEqual(error.message, "unknown flag: --json")
        }
    }

    func testAuthenticationRequiredExitWithoutJSONIsNotLoggedIn() async throws {
        let fake = try executables.fakeGH(stdout: "", stderr: "please run:  gh auth login\n", exitCode: 4)
        let status = try await client(fake).authStatus()
        XCTAssertEqual(status, .notLoggedIn)
    }

    func testUnexpectedOutputIsParseFailed() async throws {
        let fake = try executables.fakeGH(stdout: "not json")
        do {
            _ = try await client(fake).authStatus()
            XCTFail("expected parseFailed")
        } catch let error as GHError {
            XCTAssertEqual(error, .parseFailed(parser: "GHAuthParser", offset: 0))
        }
    }

    /// SEC-T11-05: tokens that gh prints on stderr never reach the error.
    func testSECT11_05_StderrIsMasked() async throws {
        let token = "ghp_" + String(repeating: "Z", count: 36)
        let fake = try executables.fakeGH(stdout: "", stderr: "HTTP 401 for token \(token)\n", exitCode: 1)
        do {
            _ = try await client(fake).authStatus()
            XCTFail("expected nonZeroExit")
        } catch let error as GHError {
            let text = try XCTUnwrap(error.detail?.text)
            XCTAssertFalse(text.contains(token))
            XCTAssertFalse(error.message.contains(token))
        }
    }

    // MARK: issue list

    func testIssues() async throws {
        let fake = try executables.fakeGH(stdout: issuesJSON)
        let issues = try await client(fake).issues(in: repository)
        XCTAssertEqual(issues.map(\.number), [12])
        XCTAssertEqual(issues.first?.assignees, ["octo-cat"])
        XCTAssertEqual(fake.recordedArguments, GHCommand.issueList(repo: repository).arguments)
        assertRanInNeutralDirectory(fake)
    }

    func testIssuesWhenAuthenticationIsRequired() async throws {
        // gh exits 4 when a command needs authentication.
        let fake = try executables.fakeGH(
            stdout: "", stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exitCode: 4)
        do {
            _ = try await client(fake).issues(in: repository)
            XCTFail("expected notLoggedIn")
        } catch let error as GHError {
            XCTAssertEqual(error, .notLoggedIn)
            XCTAssertEqual(error.suggestedCommand, "gh auth login")
        }
    }

    func testIssuesFailureIsNonZeroExit() async throws {
        let fake = try executables.fakeGH(
            stdout: "", stderr: "GraphQL: Could not resolve to a Repository\n", exitCode: 1)
        do {
            _ = try await client(fake).issues(in: repository)
            XCTFail("expected nonZeroExit")
        } catch let error as GHError {
            guard case .nonZeroExit(1, _) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.isRetryable)
        }
    }

    // MARK: pr list (ADR-0023)

    func testPullRequests() async throws {
        let fake = try executables.fakeGH(stdout: pullRequestsJSON)
        let pullRequests = try await client(fake).pullRequests(in: repository)
        XCTAssertEqual(pullRequests.map(\.number), [1])
        XCTAssertEqual(pullRequests.first?.head?.branch, "feat/1-x")
        XCTAssertEqual(fake.recordedArguments, GHCommand.prList(repo: repository).arguments)
        XCTAssertEqual(fake.recordedEnvironment, GHClient.environment(parent: hostileParent))
        assertRanInNeutralDirectory(fake)
    }

    func testPullRequestsTruncatedOutputIsNotParsed() async throws {
        let fake = try executables.fakeGH(stdout: pullRequestsJSON)
        var limits = ProcessLimits.gh
        limits.stdoutLimit = 64
        do {
            _ = try await client(fake, limits: limits).pullRequests(in: repository)
            XCTFail("expected outputTruncated")
        } catch let error as GHError {
            XCTAssertEqual(error, .outputTruncated)
        }
    }

    func testPullRequestsUnexpectedOutputIsParseFailed() async throws {
        let fake = try executables.fakeGH(stdout: #"{"message":"not a list"}"#)
        do {
            _ = try await client(fake).pullRequests(in: repository)
            XCTFail("expected parseFailed")
        } catch let error as GHError {
            guard case .parseFailed = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Limits (T15)

    func testTimeout() async throws {
        let fake = try executables.fakeGH(stdout: loggedInJSON, sleepSeconds: 30)
        var limits = ProcessLimits.gh
        limits.timeout = .milliseconds(300)
        limits.terminationGracePeriod = .milliseconds(200)
        do {
            _ = try await client(fake, limits: limits).authStatus()
            XCTFail("expected timeout")
        } catch let error as GHError {
            XCTAssertEqual(error, .timeout(seconds: 0))
        }
    }

    func testTruncatedOutputIsNotParsed() async throws {
        let fake = try executables.fakeGH(stdout: issuesJSON)
        var limits = ProcessLimits.gh
        limits.stdoutLimit = 16
        do {
            _ = try await client(fake, limits: limits).issues(in: repository)
            XCTFail("expected outputTruncated")
        } catch let error as GHError {
            XCTAssertEqual(error, .outputTruncated)
        }
    }

    func testCancellation() async throws {
        let fake = try executables.fakeGH(stdout: loggedInJSON, sleepSeconds: 30)
        let gh = client(fake)
        let task = Task { try await gh.authStatus() }
        let started = await eventually { fake.recordedArguments != nil }
        XCTAssertTrue(started, "fake gh started")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancelled")
        } catch let error as GHError {
            XCTAssertEqual(error, .cancelled)
            XCTAssertTrue(error.isSilent)
        }
    }

    // MARK: Real gh (skipped when not installed; never needs a login)

    /// Runs the installed gh with an empty HOME: it must accept the exact arguments and environment and report
    /// "not logged in" without touching the user's account or the network.
    func testRealGHWithEmptyHomeIsNotLoggedIn() async throws {
        guard GHClient.locateExecutable(candidates: GHClient.defaultExecutableCandidates) != nil else {
            throw XCTSkip("gh is not installed")
        }
        let home = executables.directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let gh = GHClient(
            parentEnvironment: ["HOME": home.path, "USER": "test", "TMPDIR": executables.directory.path],
            neutralDirectory: neutral
        )
        let status: GHAuthStatus
        do {
            status = try await gh.authStatus()
        } catch GHError.nonZeroExit(_, let detail) where detail.text.contains("unknown flag") {
            throw XCTSkip("installed gh predates `auth status --json`: \(detail.summary)")
        }
        XCTAssertEqual(status, .notLoggedIn)
        let version = try await gh.version()
        XCTAssertTrue(version.hasPrefix("gh version "), version)
        XCTAssertFalse(version.contains("\n"))
    }
}
