import Foundation
import XCTest

@testable import Overgrove

private let host = RemoteHost("gitlab.example.com")!
private let project = GitLabProject(host: host, namespace: ["group", "sub"], name: "app")!

/// glab allowlist arguments and validation (git-command-catalog.md §5.1, ADR-0026 §2–§3).
final class GLCommandTests: XCTestCase {
    /// SEC-T9-154-1: the final arguments of every case.
    func testSECT9_154_1_ArgumentSnapshot() {
        XCTAssertEqual(GLCommand.version.arguments, ["--version"])
        XCTAssertEqual(
            GLCommand.authStatus(host: host).arguments,
            ["auth", "status", "--hostname", "gitlab.example.com", "--output", "json"])
        XCTAssertEqual(
            GLCommand.issueList(project: project).arguments,
            [
                "issue", "list", "--repo", "https://gitlab.example.com/group/sub/app", "--output", "json",
                "--per-page", "50",
            ])
    }

    /// SEC-T9-154-2: repository values that could change the URL or read as an option are refused.
    func testSECT9_154_2_HostileHostsAndPathsAreRefused() {
        for name in [
            "", "localhost", "-gitlab.example.com", "gitlab-.example.com", "gitlab.example.com:22", "1.2.3.0x4",
            "0x7f000001.0x1", "10.0.0.1a",
            "user@gitlab.example.com", "10.0.0.1", "gitlab.example.com/x", "gitlab..example.com", "gitlab.example.com.",
            "gitlab.exämple.com", String(repeating: "a", count: 64) + ".com", "gitlab.example.com\n",
        ] {
            XCTAssertNil(RemoteHost(name), name)
        }
        XCTAssertNotNil(RemoteHost("gitlab.com"))
        XCTAssertNotNil(RemoteHost("git-lab.internal.example"))
        // RemoteHost (#117) lowercases, so `--hostname` and the URL always carry the lowercase name.
        XCTAssertEqual(RemoteHost("GitLab.Example.com")?.name, "gitlab.example.com")
        for (namespace, name) in [
            ([], "app"), (["group"], ""), (["group"], "-x"), (["group"], ".hidden"), (["group"], ".."),
            (["-group"], "app"), (["gr oup"], "app"), (["group"], "app?x=1"), (["group"], "app#frag"),
            (["group"], "a/b"), (["group"], "app%2F"), (Array(repeating: "g", count: 21), "app"),
            (["group"], String(repeating: "a", count: 256)),
        ] {
            XCTAssertNil(GitLabProject(host: host, namespace: namespace, name: name), "\(namespace)/\(name)")
        }
        XCTAssertEqual(
            GitLabProject(host: host, namespace: ["g_1", "sub.group"], name: "my-app.v2")?.url,
            "https://gitlab.example.com/g_1/sub.group/my-app.v2")
    }

    /// SEC-T11-154-1: no command asks for a token, writes, calls the API, opens a browser, or asks every host.
    func testSECT11_154_1_NoTokenWriteOrAllHostsCommand() {
        let all = [GLCommand.version, .authStatus(host: host), .issueList(project: project)]
        let allowed: Set<[String]> = [["--version"], ["auth", "status"], ["issue", "list"]]
        for command in all {
            let arguments = command.arguments
            let head = arguments.first == "--version" ? ["--version"] : Array(arguments.prefix(2))
            XCTAssertTrue(allowed.contains(head), "\(command)")
            for forbidden in ["-t", "--show-token", "--all", "-a", "--web", "-w", "api"] {
                XCTAssertFalse(arguments.contains(forbidden), "\(command): \(forbidden)")
            }
            XCTAssertFalse(arguments.contains { $0.lowercased().contains("token") }, "\(command)")
        }
    }
}

/// PAR-GL-01…04 (parsing-spec.md §10.4) and SEC-T15-154-1.
final class GLParserTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testPARGL01_AuthStatus() throws {
        XCTAssertEqual(
            try GLAuthParser.parse(data(GLFixtures.authLoggedOut)), [GLHostStatus(host: "gitlab.com", user: nil)])
        let loggedIn = try GLAuthParser.parse(data(GLFixtures.authLoggedIn))
        XCTAssertEqual(loggedIn, [GLHostStatus(host: "gitlab.example.com", user: "octo")])
        XCTAssertTrue(loggedIn[0].isLoggedIn)
        // A success without a user is not trusted as logged in.
        XCTAssertFalse(
            try GLAuthParser.parse(data(#"{"hosts":[{"host":"h.example","state":"success"}]}"#))[0].isLoggedIn)
        XCTAssertThrowsError(try GLAuthParser.parse(data(GLFixtures.authUnconfigured)))
        XCTAssertThrowsError(try GLAuthParser.parse(data("not json")))
    }

    func testPARGL02_IssueList() throws {
        let issues = try GLIssueParser.parse(data(GLFixtures.issues))
        XCTAssertEqual(issues.map(\.number), [8724, 8721])
        XCTAssertEqual(issues[0].state, .open)
        XCTAssertEqual(issues[0].title, "Issue title")
        XCTAssertEqual(issues[0].labels.map(\.name), ["type::bug", "priority::2"])
        XCTAssertEqual(issues[0].assignees, ["user"])
        XCTAssertEqual(issues[0].url.absoluteString, "https://gitlab.com/group/project/-/work_items/8724")
        XCTAssertNotNil(issues[0].updatedAt)
        XCTAssertEqual(try GLIssueParser.parse(data("[]")), [])
    }

    /// PAR-GL-03: only a non-array fails; one bad entry drops itself.
    func testPARGL03_OneBadEntryDropsOnlyItself() throws {
        let good =
            #"{"iid":7,"title":"t","state":"opened","web_url":"https://gitlab.example.com/g/p/-/issues/7","updated_at":"2026-11-08T03:14:08Z"}"#
        for bad in [
            #"{"title":"no iid","state":"opened","web_url":"https://x.example/a","updated_at":"2026-11-08T03:14:08Z"}"#,
            #"{"iid":1,"state":"opened","web_url":"https://x.example/a","updated_at":"2026-11-08T03:14:08Z"}"#,
            #"{"iid":1,"title":"t","state":"locked","web_url":"https://x.example/a","updated_at":"2026-11-08T03:14:08Z"}"#,
            #"{"iid":1,"title":"t","state":"opened","web_url":"http://x.example/a","updated_at":"2026-11-08T03:14:08Z"}"#,
            #"{"iid":1,"title":"t","state":"opened","web_url":"https://x.example/a"}"#,
            #"{"iid":0,"title":"t","state":"opened","web_url":"https://x.example/a","updated_at":"2026-11-08T03:14:08Z"}"#,
            "42", "null", "[]",
        ] {
            XCTAssertEqual(try GLIssueParser.parse(data("[\(bad),\(good)]")).map(\.number), [7], bad)
        }
        for json in [#"{"message":"404"}"#, "not json", "", #"[{"iid":1"#] {
            XCTAssertThrowsError(try GLIssueParser.parse(data(json)), json)
        }
    }

    /// SEC-T15-154-1: issue count, title length, labels, and label names are capped; the body is never read.
    func testSECT15_154_1_IssueOutputIsCapped() throws {
        let longTitle = String(repeating: "t", count: 5_000)
        let labels = (0..<80).map { "\"\(String(repeating: "l", count: 300))\($0)\"" }.joined(separator: ",")
        let assignees = (0..<80).map { #"{"username":"u\#($0)"}"# }.joined(separator: ",")
        let entry = { (n: Int) in
            #"{"iid":\#(n),"title":"\#(longTitle)","state":"opened","labels":[\#(labels)],"assignees":[\#(assignees)],"description":"x","web_url":"https://g.example/a/b/-/issues/\#(n)","updated_at":"2026-11-08T03:14:08Z"}"#
        }
        let json = "[" + (1...250).map(entry).joined(separator: ",") + "]"
        let issues = try GLIssueParser.parse(data(json))
        XCTAssertEqual(issues.count, GLIssueParser.maximumIssues)
        XCTAssertEqual(issues[0].title.count, GLIssueParser.maximumTitle)
        XCTAssertEqual(issues[0].labels.count, GLIssueParser.maximumLabels)
        XCTAssertEqual(issues[0].labels[0].name.count, GLIssueParser.maximumLabelName)
        XCTAssertEqual(issues[0].assignees.count, GLIssueParser.maximumAssignees)
    }

    func testPARGL04_VersionLine() {
        XCTAssertEqual(
            GLClient.parseVersion(data("glab 1.128.0 (519ea19f7)\n")), GitVersion(major: 1, minor: 128, patch: 0))
        for line in ["gt version 1.1.0 (2026-11-05)", "1.4.3", "glab version 1.128.0", "glab 1.128", "glab 1.x.0", ""] {
            XCTAssertNil(GLClient.parseVersion(data(line)), line)
        }
    }
}

/// GLClient: setup check, executable check, hardened environment, neutral directory, and host trust (ADR-0026 §2, §6).
final class GLClientTests: XCTestCase {
    private var executables: TestExecutables!
    private var neutral: URL!
    private var home: URL!

    private let hostileParent: [String: String] = [
        "GITLAB_TOKEN": "glpat-" + String(repeating: "a", count: 20),
        "GITLAB_ACCESS_TOKEN": "x", "OAUTH_TOKEN": "x", "GITLAB_HOST": "evil.example", "GITLAB_URI": "evil.example",
        "GL_HOST": "evil.example", "GITLAB_REPO": "evil/repo", "GLAB_CONFIG_DIR": "/evil", "GLAB_CA_CERT": "/evil.pem",
        "GLAB_SKIP_TLS_VERIFY": "true", "GLAB_CLIENT_CERT": "/evil", "GLAB_PROXY": "http://evil.example",
        "GLAB_SEND_TELEMETRY": "true", "GLAB_CHECK_UPDATE": "true", "GLAB_DEBUG": "true", "GLAB_DEBUG_HTTP": "true",
        "GODEBUG": "x509ignoreCN=0", "SSL_CERT_FILE": "/evil.pem", "SSL_CERT_DIR": "/evil", "GIT_DIR": "/evil/.git",
        "HTTPS_PROXY": "http://evil.example", "BROWSER": "/evil", "EDITOR": "/evil", "XDG_CONFIG_HOME": "/evil",
        "PATH": "/evil/bin:/usr/bin", "HOME": "/tmp/overgrove-home", "USER": "example", "TMPDIR": "/tmp/example/",
    ]

    override func setUpWithError() throws {
        executables = try TestExecutables()
        neutral = executables.directory.appendingPathComponent("neutral", isDirectory: true)
        home = executables.directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: neutral, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        executables.remove()
    }

    private func setUpGlabConfig(_ relative: String = ".config/glab-cli/config.yml") throws {
        let file = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hosts: {}\n".utf8).write(to: file)
    }

    private func client(_ fake: FakeForgeCLI?, limits: ProcessLimits = .gh) -> GLClient {
        GLClient(
            parentEnvironment: hostileParent, neutralDirectory: neutral,
            executableCandidates: fake.map { [$0.executable] } ?? [], limits: limits, home: home)
    }

    /// SEC-T10-154-1: the child environment is exactly the allowlist; telemetry and update checks are off, and no
    /// token, host, config, TLS, proxy, debug, or browser variable from the parent reaches glab.
    func testSECT10_154_1_EnvironmentIsExactlyTheAllowlist() async throws {
        let expected = GLClient.environment(parent: hostileParent, home: home)
        XCTAssertEqual(Set(expected.keys), Set(GLClient.fixedEnvironment.keys).union(["HOME", "USER", "TMPDIR"]))
        // glab reads the configuration that was checked, not the parent's HOME.
        XCTAssertEqual(expected["HOME"], home.path)
        XCTAssertEqual(expected["GLAB_SEND_TELEMETRY"], "false")
        XCTAssertEqual(expected["GLAB_CHECK_UPDATE"], "false")
        XCTAssertEqual(expected["PATH"], GitEnvironment.path)
        for key in [
            "GITLAB_TOKEN", "GITLAB_HOST", "GLAB_CONFIG_DIR", "GLAB_DEBUG_HTTP", "SSL_CERT_FILE", "HTTPS_PROXY",
        ] {
            XCTAssertNil(expected[key], key)
        }
        try setUpGlabConfig()
        let fake = try executables.fakeGlab(authJSON: GLFixtures.authLoggedOut, authExit: 1)
        _ = try await client(fake).hostStatus(host)
        XCTAssertEqual(fake.recordedEnvironment, expected)
        let recorded = fake.recordedDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(recorded, neutral.resolvingSymlinksInPath().path, "the neutral directory, never a repository")
    }

    /// SEC-T13-154-1: without glab's configuration file nothing runs, so glab cannot create one in the user's folder.
    func testSECT13_154_1_NothingRunsWithoutGlabConfiguration() async throws {
        let fake = try executables.fakeGlab()
        do {
            _ = try await client(fake).issues(in: project)
            XCTFail("expected notSetUp")
        } catch let error as GLError {
            XCTAssertEqual(error, .notSetUp)
        }
        XCTAssertEqual(fake.calls, [], "not even --version")
        // Either place glab reads counts.
        try setUpGlabConfig("Library/Application Support/glab-cli/config.yml")
        _ = try await client(fake).hostStatus(host)
        XCTAssertFalse(fake.calls.isEmpty)
    }

    /// SEC-T13-154-2: a `glab` that does not print glab's version line (another tool), or an older glab, runs nothing
    /// else.
    func testSECT13_154_2_OnlyAVerifiedGlabRuns() async throws {
        try setUpGlabConfig()
        for (line, expected) in [
            ("gt version 1.1.0", GLError.notInstalled), ("1.4.3", .notInstalled),
            ("glab 1.127.9 (abc)", .unsupportedVersion(found: "1.127.9")),
        ] {
            let fake = try executables.fakeGlab(versionLine: line, authJSON: GLFixtures.authLoggedIn)
            do {
                _ = try await client(fake).issues(in: project)
                XCTFail("expected \(expected)")
            } catch let error as GLError {
                XCTAssertEqual(error, expected, line)
            }
            XCTAssertEqual(fake.calls, ["--version"], line)
        }
        do {
            _ = try await client(nil).hostStatus(host)
            XCTFail("expected notInstalled")
        } catch let error as GLError {
            XCTAssertEqual(error, .notInstalled)
        }
    }

    /// SEC-T11-154-2: issues are read only for a host glab reports logged in; otherwise `issue list` never runs, so no
    /// request goes to a host the user did not log in to.
    func testSECT11_154_2_IssuesOnlyForALoggedInHost() async throws {
        try setUpGlabConfig()
        for auth in [GLFixtures.authLoggedOut, GLFixtures.authUnconfigured, "garbage"] {
            let fake = try executables.fakeGlab(authJSON: auth, authExit: 1, issuesJSON: GLFixtures.issues)
            do {
                _ = try await client(fake).issues(in: project)
                XCTFail("expected notLoggedIn")
            } catch let error as GLError {
                XCTAssertEqual(error, .notLoggedIn(host: "gitlab.example.com"))
            }
            XCTAssertEqual(fake.calls.count, 2, "--version and auth status only")
            XCTAssertFalse(fake.calls.contains { $0.hasPrefix("issue") })
        }
        let fake = try executables.fakeGlab(authJSON: GLFixtures.authLoggedIn, issuesJSON: GLFixtures.issues)
        let issues = try await client(fake).issues(in: project)
        XCTAssertEqual(issues.map(\.number), [8724, 8721])
        XCTAssertEqual(
            fake.calls,
            [
                "--version", "auth status --hostname gitlab.example.com --output json",
                "issue list --repo https://gitlab.example.com/group/sub/app --output json --per-page 50",
            ])
    }

    /// SEC-T11-154-3: glab's stderr is not kept, so a token it prints cannot reach the screen or a log.
    func testSECT11_154_3_StderrIsDropped() async throws {
        try setUpGlabConfig()
        let token = "glpat-" + String(repeating: "z", count: 20)
        let fake = try executables.fakeGlab(
            authJSON: GLFixtures.authLoggedIn, issuesJSON: "", issueExit: 1, stderr: "error with \(token)")
        do {
            _ = try await client(fake).issues(in: project)
            XCTFail("expected failed")
        } catch let error as GLError {
            XCTAssertEqual(error, .failed(code: 1))
            XCTAssertFalse(error.message.contains(token))
            XCTAssertFalse(String(describing: error).contains(token))
        }
    }

    /// SEC-T13-154-3: with glab's configuration in place, a whole load (version, auth status, issue list) leaves the
    /// HOME folder exactly as it was: the app writes nothing there.
    func testSECT13_154_3_ALoadLeavesHomeUnchanged() async throws {
        try setUpGlabConfig()
        func tree() throws -> [String: Data] {
            var files: [String: Data] = [:]
            let enumerator = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                let relative = String(url.path.dropFirst(home.path.count))
                files[relative] = (try? Data(contentsOf: url)) ?? Data()
            }
            return files
        }
        let before = try tree()
        let fake = try executables.fakeGlab(authJSON: GLFixtures.authLoggedIn, issuesJSON: GLFixtures.issues)
        _ = try await client(fake).issues(in: project)
        XCTAssertEqual(fake.calls.count, 3)
        XCTAssertEqual(try tree(), before)
    }

    func testTruncatedIssueOutputIsNotParsed() async throws {
        try setUpGlabConfig()
        let fake = try executables.fakeGlab(authJSON: GLFixtures.authLoggedIn, issuesJSON: GLFixtures.issues)
        var limits = ProcessLimits.gh
        limits.stdoutLimit = 512
        do {
            _ = try await client(fake, limits: limits).issues(in: project)
            XCTFail("expected outputTruncated")
        } catch let error as GLError {
            XCTAssertEqual(error, .outputTruncated)
        }
    }
}
