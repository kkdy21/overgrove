import Foundation
import XCTest

@testable import Overgrove

private let instance = GiteaInstance("https://git.example.com")!
private let repository = GiteaRepository(instance: instance, owner: "acme", name: "widgets")!

/// gt allowlist arguments and validation (git-command-catalog.md §5.1, ADR-0026 §2–§3).
final class GTCommandTests: XCTestCase {
    /// SEC-T9-449-1: the final arguments of every case.
    func testSECT9_449_1_ArgumentSnapshot() {
        XCTAssertEqual(GTCommand.version.arguments, ["--version"])
        XCTAssertEqual(GTCommand.authStatus.arguments, ["auth", "status", "--json", "host,user,credential_available"])
        XCTAssertEqual(
            GTCommand.issueList(repository: repository).arguments,
            [
                "issue", "list", "--host", "https://git.example.com", "--repo", "acme/widgets", "--state", "open",
                "--kind", "issues", "--limit", "200", "--no-input", "--json",
                "number,title,state,labels,assignees,updated_at,url",
            ])
        let based = GiteaRepository(
            instance: GiteaInstance("https://code.example.org:8443/gitea")!, owner: "o", name: "r")!
        XCTAssertEqual(
            Array(GTCommand.issueList(repository: based).arguments[2...5]),
            ["--host", "https://code.example.org:8443/gitea", "--repo", "o/r"])
    }

    /// SEC-T9-449-2: instance URLs and repository names that could change the target or read as an option are refused.
    func testSECT9_449_2_HostileInstancesAndNamesAreRefused() {
        for text in [
            "", "git.example.com", "http://git.example.com", "HTTPS://git.example.com", "https://Git.example.com",
            "https://git.example.com/", "https://user@git.example.com", "https://user:pw@git.example.com",
            "https://10.0.0.1", "https://[::1]", "https://localhost", "https://git.example.com:0",
            "https://git.example.com:65536", "https://git.example.com:080", "https://git.example.com:",
            "https://-x.example.com",
            "https://git.example.com?x=1", "https://git.example.com#f", "https://git.example.com/a?b",
            "https://git.example.com/../x", "https://git.example.com/.hidden", "https://git.example.com/-x",
            "https://git.example.com/a//b", "https://git.example.com/a/b/c/d/e/f", "https://git.example.com/%2e",
            "https://gït.example.com", "https://git.example.com\n", " https://git.example.com",
        ] {
            XCTAssertNil(GiteaInstance(text), text)
        }
        for text in ["https://gitea.com", "https://code.example.org:8443/gitea", "https://g.example.com/a/b/c/d/e"] {
            XCTAssertEqual(GiteaInstance(text)?.url, text)
        }
        XCTAssertEqual(GiteaInstance("https://code.example.org:8443/gitea")?.port, 8443)
        XCTAssertEqual(GiteaInstance("https://code.example.org:8443/gitea")?.basePath, ["gitea"])
        for (owner, name) in [
            ("", "r"), ("o", ""), ("-o", "r"), ("o", "-r"), (".o", "r"), ("o", ".."), ("o/x", "r"), ("o", "r?x"),
            ("o", "r#x"), ("o", "r%2F"), ("o w", "r"), (String(repeating: "o", count: 41), "r"),
            ("o", String(repeating: "r", count: 101)), ("ö", "r"),
        ] {
            XCTAssertNil(GiteaRepository(instance: instance, owner: owner, name: name), "\(owner)/\(name)")
        }
        XCTAssertEqual(
            GiteaRepository(instance: instance, owner: "my_org.1", name: "my-repo.v2")?.slug, "my_org.1/my-repo.v2")
    }

    /// SEC-T11-449-1: no command asks for a token, writes, calls the API, runs an extension, opens a browser, or asks the
    /// server to verify credentials.
    func testSECT11_449_1_NoTokenWriteApiOrExtensionCommand() {
        let all = [GTCommand.version, .authStatus, .issueList(repository: repository)]
        let allowed: Set<[String]> = [["--version"], ["auth", "status"], ["issue", "list"]]
        for command in all {
            let arguments = command.arguments
            let head = arguments.first == "--version" ? ["--version"] : Array(arguments.prefix(2))
            XCTAssertTrue(allowed.contains(head), "\(command)")
            for forbidden in [
                "--verify", "--web", "-w", "api", "--interactive", "--sudo", "--debug", "--template", "-q", "--jq",
                "--yes", "-y", "--cwd", "--remote",
            ] {
                XCTAssertFalse(arguments.contains(forbidden), "\(command): \(forbidden)")
            }
            XCTAssertFalse(arguments.contains { $0.lowercased().contains("token") }, "\(command)")
        }
        // The body is never requested.
        XCTAssertFalse(GTCommand.issueFields.split(separator: ",").contains("body"))
    }
}

/// PAR-GT-01…04 (parsing-spec.md §10.5) and SEC-T15-449-1.
final class GTParserTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testPARGT01_AuthStatus() throws {
        XCTAssertEqual(try GTAuthParser.parse(data(GTFixtures.authNone)), [])
        XCTAssertEqual(
            try GTAuthParser.parse(data(GTFixtures.authHTTPInstance)),
            [GTAccount(host: "http://127.0.0.1:18449", user: nil, credentialAvailable: true)])
        XCTAssertEqual(
            try GTAuthParser.parse(data(GTFixtures.authAccounts)),
            [
                GTAccount(host: "https://git.example.com", user: "alice", credentialAvailable: true),
                GTAccount(host: "https://other.example.com", user: "bob", credentialAvailable: false),
                GTAccount(host: "https://code.example.org:8443/gitea", user: "alice", credentialAvailable: true),
            ])
        // Only a JSON `true` counts; an entry without a host is dropped.
        XCTAssertEqual(
            try GTAuthParser.parse(
                data(
                    #"[{"host":"https://a.example.com","credential_available":"true"},{"credential_available":true},{"host":"","credential_available":true},42]"#
                )),
            [GTAccount(host: "https://a.example.com", user: nil, credentialAvailable: false)])
        for json in [#"{"host":"https://a.example.com"}"#, "not json", "", "Error: not logged in"] {
            XCTAssertThrowsError(try GTAuthParser.parse(data(json)), json)
        }
    }

    func testPARGT02_IssueList() throws {
        let issues = try GTIssueParser.parse(data(GTFixtures.issues))
        XCTAssertEqual(issues.map(\.number), [7, 8])
        XCTAssertEqual(issues[0].state, .open)
        XCTAssertEqual(issues[0].title, "Crash when \u{202E}opening")
        XCTAssertEqual(
            issues[0].labels, [.init(name: "bug", color: "ee0701"), .init(name: "area/ui", color: "00aabb")])
        XCTAssertEqual(issues[0].assignees, ["alice", "bob"])
        XCTAssertEqual(issues[0].url.absoluteString, "https://git.example.com/acme/widgets/issues/7")
        XCTAssertEqual(issues[0].updatedAt, ISO8601DateFormatter().date(from: "2026-11-07T00:30:00Z"))
        XCTAssertEqual(issues[1].labels, [])
        XCTAssertEqual(issues[1].assignees, [])
        XCTAssertEqual(try GTIssueParser.parse(data("[]")), [])
    }

    /// PAR-GT-03: only a non-array fails; one bad entry, label, or assignee drops only itself.
    func testPARGT03_OneBadEntryDropsOnlyItself() throws {
        let good =
            ##"{"number":7,"title":"t","state":"open","labels":[{"name":"ok","color":"zzzzzz"},{"color":"ffffff"},"x",{"name":"c","color":"#A1B2C3"}],"assignees":["a",3,""],"url":"https://g.example.com/o/r/issues/7","updated_at":"2026-11-08T03:14:08Z"}"##
        for bad in [
            #"{"title":"no number","state":"open","url":"https://x.example/a","updated_at":"2026-11-08T03:14:08Z"}"#,
            #"{"number":1,"state":"open","url":"https://x.example/a","updated_at":"2026-11-08T03:14:08Z"}"#,
            #"{"number":1,"title":"t","state":"opened","url":"https://x.example/a","updated_at":"2026-11-08T03:14:08Z"}"#,
            #"{"number":1,"title":"t","state":"open","url":"http://x.example/a","updated_at":"2026-11-08T03:14:08Z"}"#,
            #"{"number":1,"title":"t","state":"open","url":"https://x.example/a"}"#,
            #"{"number":0,"title":"t","state":"open","url":"https://x.example/a","updated_at":"2026-11-08T03:14:08Z"}"#,
            #"{"number":"1","title":"t","state":"open","url":"https://x.example/a","updated_at":"2026-11-08T03:14:08Z"}"#,
            "42", "null", "[]",
        ] {
            XCTAssertEqual(try GTIssueParser.parse(data("[\(bad),\(good)]")).map(\.number), [7], bad)
        }
        let issue = try GTIssueParser.parse(data("[\(good)]"))[0]
        XCTAssertEqual(issue.labels, [.init(name: "ok", color: nil), .init(name: "c", color: "a1b2c3")])
        XCTAssertEqual(issue.assignees, ["a"])
        for json in [#"{"message":"404"}"#, "not json", "", #"[{"number":1"#] {
            XCTAssertThrowsError(try GTIssueParser.parse(data(json)), json)
        }
    }

    /// SEC-T15-449-1: issue count, title length, labels, and label names are capped; the body is never read.
    func testSECT15_449_1_IssueOutputIsCapped() throws {
        let longTitle = String(repeating: "t", count: 5_000)
        let labels = (0..<80).map { #"{"name":"\#(String(repeating: "l", count: 300))\#($0)","color":"ffffff"}"# }
            .joined(separator: ",")
        let entry = { (n: Int) in
            #"{"number":\#(n),"title":"\#(longTitle)","state":"open","labels":[\#(labels)],"body":"x","url":"https://g.example.com/a/b/issues/\#(n)","updated_at":"2026-11-08T03:14:08Z"}"#
        }
        let json = "[" + (1...250).map(entry).joined(separator: ",") + "]"
        let issues = try GTIssueParser.parse(data(json))
        XCTAssertEqual(issues.count, GTIssueParser.maximumIssues)
        XCTAssertEqual(issues[0].title.count, GTIssueParser.maximumTitle)
        XCTAssertEqual(issues[0].labels.count, GTIssueParser.maximumLabels)
        XCTAssertEqual(issues[0].labels[0].name.count, GTIssueParser.maximumLabelName)
    }

    /// PAR-GT-04: only gt's `gt version X.Y.Z` line is accepted (Graphite's `gt` prints a bare number).
    func testPARGT04_VersionLine() {
        XCTAssertEqual(
            GTClient.parseVersion(data("gt version 1.1.0 (2026-11-05)\nhttps://gitea.com/gitea/cli/releases\n")),
            GitVersion(major: 1, minor: 1, patch: 0))
        for line in [
            "1.4.3", "gt 1.1.0", "glab 1.128.0 (519ea19f7)", "gt version 1.1", "gt version v1.1.0", "gt version 1.x.0",
            "graphite version 1.1.0", "",
        ] {
            XCTAssertNil(GTClient.parseVersion(data(line)), line)
        }
    }
}

/// GTClient: executable check, hardened environment, neutral directory, and instance trust (ADR-0026 §2, §6).
final class GTClientTests: XCTestCase {
    private var executables: TestExecutables!
    private var neutral: URL!

    private let hostileParent: [String: String] = [
        "GITEA_TOKEN": String(repeating: "a", count: 40), "GITEA_CLI_HOST": "https://evil.example",
        "GITEA_INSTANCE_URL": "https://evil.example", "GITEA_INSTANCE_INSECURE": "true",
        "GITEA_INSTANCE_SSH_HOST": "evil.example", "GITEA_SERVER_URL": "https://evil.example",
        "GITHUB_SERVER_URL": "https://evil.example", "GITEA_CLI_CONFIG_DIR": "/evil", "GITEA_CLI_DATA_DIR": "/evil",
        "GITEA_CLI_REPO": "evil/repo", "GITEA_CLI_USER": "evil", "GITEA_CLI_EDITOR": "/evil",
        "GITEA_CLI_ERROR_FORMAT": "json", "GITEA_CLI_HTTP_TIMEOUT": "999",
        "GITEA_CLI_DOWNLOAD_URL": "https://evil.example",
        "GITEA_CLI_NO_UPDATE_NOTIFIER": "", "GITEA_CLI_NO_EXTENSIONS": "", "CLICOLOR_FORCE": "1",
        "GODEBUG": "x509ignoreCN=0", "SSL_CERT_FILE": "/evil.pem", "SSL_CERT_DIR": "/evil", "GIT_DIR": "/evil/.git",
        "HTTPS_PROXY": "http://evil.example", "BROWSER": "/evil", "EDITOR": "/evil", "VISUAL": "/evil",
        "PAGER": "/evil", "XDG_CONFIG_HOME": "/evil", "PATH": "/evil/bin:/usr/bin", "HOME": "/Users/example",
        "USER": "example", "TMPDIR": "/tmp/example/",
    ]

    override func setUpWithError() throws {
        executables = try TestExecutables()
        neutral = executables.directory.appendingPathComponent("neutral", isDirectory: true)
        try FileManager.default.createDirectory(at: neutral, withIntermediateDirectories: true)
    }

    override func tearDown() {
        executables.remove()
    }

    private func fake(
        versionLine: String = "gt version 1.1.0 (2026-11-05)", authJSON: String = GTFixtures.authAccounts,
        issuesJSON: String = GTFixtures.issues, issueExit: Int32 = 0, stderr: String = ""
    ) throws -> FakeGt {
        try FakeGt(
            in: executables, versionLine: versionLine, authJSON: authJSON, issuesJSON: issuesJSON, issueExit: issueExit,
            stderr: stderr)
    }

    private func client(_ fake: FakeGt?, limits: ProcessLimits = .gh) -> GTClient {
        GTClient(
            parentEnvironment: hostileParent, neutralDirectory: neutral,
            executableCandidates: fake.map { [$0.executable] } ?? [], limits: limits)
    }

    /// SEC-T10-449-1: the child environment is exactly the allowlist; the update notifier and extensions are off, and
    /// no token, instance, insecure-TLS, config, repository, debug, proxy, pager, or browser variable reaches gt.
    func testSECT10_449_1_EnvironmentIsExactlyTheAllowlist() async throws {
        let expected = GTClient.environment(parent: hostileParent)
        XCTAssertEqual(Set(expected.keys), Set(GTClient.fixedEnvironment.keys).union(["HOME", "USER", "TMPDIR"]))
        XCTAssertEqual(expected["GITEA_CLI_NO_UPDATE_NOTIFIER"], "1")
        XCTAssertEqual(expected["GITEA_CLI_NO_EXTENSIONS"], "1")
        XCTAssertEqual(expected["PATH"], GitEnvironment.path)
        for key in [
            "GITEA_TOKEN", "GITEA_CLI_HOST", "GITEA_INSTANCE_URL", "GITEA_INSTANCE_INSECURE", "GITEA_CLI_CONFIG_DIR",
            "GITEA_CLI_REPO", "GITEA_SERVER_URL", "CLICOLOR_FORCE", "SSL_CERT_FILE", "HTTPS_PROXY", "PAGER",
        ] {
            XCTAssertNil(expected[key], key)
        }
        let fake = try fake()
        _ = try await client(fake).loggedInInstances()
        XCTAssertEqual(fake.recordedEnvironment, expected)
        let recorded = fake.recordedDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(recorded, neutral.resolvingSymlinksInPath().path, "the neutral directory, never a repository")
    }

    /// SEC-T13-449-1: a `gt` that does not print gt's version line (Graphite's CLI, another tool), or an older gt, runs
    /// nothing else.
    func testSECT13_449_1_OnlyAVerifiedGtRuns() async throws {
        for (line, expected) in [
            ("1.4.3", GTError.notInstalled), ("glab 1.128.0 (abc)", .notInstalled), ("gt 1.1.0", .notInstalled),
            ("gt version 1.0.9 (2026-11-02)", .unsupportedVersion(found: "1.0.9")),
        ] {
            let fake = try fake(versionLine: line)
            do {
                _ = try await client(fake).issues(in: repository)
                XCTFail("expected \(expected)")
            } catch let error as GTError {
                XCTAssertEqual(error, expected, line)
            }
            XCTAssertEqual(fake.calls, ["--version"], line)
        }
        do {
            _ = try await client(nil).loggedInInstances()
            XCTFail("expected notInstalled")
        } catch let error as GTError {
            XCTAssertEqual(error, .notInstalled)
        }
    }

    /// SEC-T11-449-2: issues are read only for an instance gt reports credentials for, matched by its validated https
    /// URL; otherwise `issue list` never runs, so no request goes to an instance the user did not log in to.
    func testSECT11_449_2_IssuesOnlyForAnInstanceWithCredentials() async throws {
        let others: [(String, GiteaRepository)] = [
            (GTFixtures.authNone, repository),
            (GTFixtures.authHTTPInstance, repository),
            ("garbage", repository),
            // Credentials exist, but not usable.
            (
                GTFixtures.authAccounts,
                GiteaRepository(
                    instance: GiteaInstance("https://other.example.com")!, owner: "o", name: "r")!
            ),
            // Same host, different base path or port.
            (
                GTFixtures.authAccounts,
                GiteaRepository(
                    instance: GiteaInstance("https://code.example.org:8443")!, owner: "o", name: "r")!
            ),
            (
                GTFixtures.authAccounts,
                GiteaRepository(
                    instance: GiteaInstance("https://code.example.org/gitea")!, owner: "o", name: "r")!
            ),
        ]
        for (auth, target) in others {
            let fake = try fake(authJSON: auth)
            do {
                _ = try await client(fake).issues(in: target)
                XCTFail("expected notLoggedIn")
            } catch let error as GTError {
                XCTAssertEqual(error, .notLoggedIn(instance: target.instance.url), auth)
            }
            XCTAssertEqual(fake.calls.count, 2, "--version and auth status only")
            XCTAssertFalse(fake.calls.contains { $0.hasPrefix("issue") })
        }
        let fake = try fake()
        let instances = try await client(fake).loggedInInstances()
        XCTAssertEqual(instances.map(\.url), ["https://git.example.com", "https://code.example.org:8443/gitea"])
        let issues = try await client(fake).issues(in: repository)
        XCTAssertEqual(issues.map(\.number), [7, 8])
        XCTAssertEqual(
            Array(fake.calls.suffix(3)),
            [
                "--version", "auth status --json host,user,credential_available",
                "issue list --host https://git.example.com --repo acme/widgets --state open --kind issues --limit 200 --no-input --json number,title,state,labels,assignees,updated_at,url",
            ])
        // gt's own "no account" exit code still reads as not logged in.
        let refused = try self.fake(issuesJSON: "", issueExit: 4)
        do {
            _ = try await client(refused).issues(in: repository)
            XCTFail("expected notLoggedIn")
        } catch let error as GTError {
            XCTAssertEqual(error, .notLoggedIn(instance: "https://git.example.com"))
        }
    }

    /// SEC-T11-449-3: gt's stderr is not kept, so a token it prints cannot reach the screen or a log.
    func testSECT11_449_3_StderrIsDropped() async throws {
        let token = String(repeating: "f", count: 40)
        let fake = try fake(issuesJSON: "", issueExit: 1, stderr: "error with \(token)")
        do {
            _ = try await client(fake).issues(in: repository)
            XCTFail("expected failed")
        } catch let error as GTError {
            XCTAssertEqual(error, .failed(code: 1))
            XCTAssertFalse(error.message.contains(token))
            XCTAssertFalse(String(describing: error).contains(token))
        }
    }

    func testTruncatedIssueOutputIsNotParsed() async throws {
        let fake = try fake()
        var limits = ProcessLimits.gh
        limits.stdoutLimit = 400
        do {
            _ = try await client(fake, limits: limits).issues(in: repository)
            XCTFail("expected outputTruncated")
        } catch let error as GTError {
            XCTAssertEqual(error, .outputTruncated)
        }
    }
}
