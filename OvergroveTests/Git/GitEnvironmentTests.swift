import Foundation
import XCTest

@testable import Overgrove

/// GitEnvironment: security-review.md §3.1–§3.2, SEC-T10-01/02.
final class GitEnvironmentTests: XCTestCase {
    private var executables: TestExecutables!

    override func setUpWithError() throws {
        executables = try TestExecutables()
    }

    override func tearDown() {
        executables.remove()
    }

    private let hostileParent: [String: String] = [
        "GIT_DIR": "/evil/.git",
        "GIT_WORK_TREE": "/evil",
        "GIT_CONFIG_PARAMETERS": "'core.fsmonitor=touch /tmp/pwned'",
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "core.hooksPath",
        "GIT_CONFIG_VALUE_0": "/evil/hooks",
        "GIT_SSH_COMMAND": "evil-ssh",
        "GIT_EXEC_PATH": "/evil/libexec",
        "GIT_EXTERNAL_DIFF": "/evil/diff",
        "DYLD_INSERT_LIBRARIES": "/evil/lib.dylib",
        "PATH": "/evil/bin:/usr/bin",
        "HOME": "/Users/example",
        "TMPDIR": "/tmp/example/",
        "SSH_AUTH_SOCK": "/tmp/agent.sock",
        "GIT_ALLOW_PROTOCOL": "evilhelper:ext:https",
    ]

    func testSECT10_01_DangerousParentVariablesNeverReachGit() {
        let environment = GitEnvironment.environment(parent: hostileParent, allowsTransport: true)
        for key in [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0",
            "GIT_CONFIG_VALUE_0", "GIT_EXEC_PATH", "GIT_EXTERNAL_DIFF", "DYLD_INSERT_LIBRARIES",
        ] {
            XCTAssertNil(environment[key], key)
        }
        XCTAssertEqual(
            environment["GIT_SSH_COMMAND"], GitEnvironment.defaultSSHCommand, "the parent's value is ignored")
        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertEqual(environment["SSH_AUTH_SOCK"], "/tmp/agent.sock")
        XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(environment["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertEqual(environment["GIT_ASKPASS"], "")
        XCTAssertEqual(environment["GIT_PROXY_COMMAND"], "")
        XCTAssertEqual(environment["LC_ALL"], "C")
        XCTAssertEqual(
            environment["GIT_ALLOW_PROTOCOL"], "https:ssh:git:file:http", "the parent's transport list is ignored")
    }

    /// #212: queries never use a transport, so a promisor remote cannot make them lazy-fetch (and run the
    /// repository's uploadpack or credential helper). An empty allow list refuses every transport on every
    /// supported git; GIT_NO_LAZY_FETCH (git 2.44.1+ and the 2024 backports, #317) is a second layer for all commands.
    func testQueriesAllowNoTransport() {
        let query = GitEnvironment.environment(parent: hostileParent, allowsTransport: false)
        XCTAssertEqual(query["GIT_ALLOW_PROTOCOL"], "", "an empty list allows nothing")
        XCTAssertEqual(query["GIT_NO_LAZY_FETCH"], "1")
        let fetch = GitEnvironment.environment(parent: hostileParent, allowsTransport: true)
        XCTAssertEqual(fetch["GIT_ALLOW_PROTOCOL"], GitEnvironment.allowedProtocols)
        XCTAssertEqual(fetch["GIT_NO_LAZY_FETCH"], "1")
        XCTAssertEqual(
            Set(query.keys), Set(fetch.keys), "the same variables; only the transport list differs")
    }

    /// #215: a caller that does not choose gets no transport (secure default).
    func testDefaultAllowsNoTransport() {
        XCTAssertEqual(GitEnvironment.environment(parent: [:])["GIT_ALLOW_PROTOCOL"], "")
        XCTAssertEqual(GitEnvironment.environment(parent: hostileParent)["GIT_ALLOW_PROTOCOL"], "")
        XCTAssertEqual(
            GitEnvironment.environment(parent: [:], trustedSSHCommand: "ssh -i ~/.ssh/work")["GIT_ALLOW_PROTOCOL"], "")
        XCTAssertEqual(
            GitEnvironment.environment(parent: [:]), GitEnvironment.environment(parent: [:], allowsTransport: false))
    }

    func testOnlyBuiltInTransportsAreAllowed() {
        // Snapshot of security-review.md §3.2; change both together. Remote helpers chosen by a repository
        // (`<helper>::` URLs, `remote.<n>.vcs`, `insteadOf`) are refused even with `protocol.<helper>.allow=always` (T5).
        XCTAssertEqual(GitEnvironment.allowedProtocols, "https:ssh:git:file:http")
        XCTAssertEqual(
            GitEnvironment.environment(parent: [:], allowsTransport: true)["GIT_ALLOW_PROTOCOL"],
            GitEnvironment.allowedProtocols)
        XCTAssertEqual(
            GitEnvironment.environment(parent: [:], trustedSSHCommand: "ssh -i ~/.ssh/work", allowsTransport: true)[
                "GIT_ALLOW_PROTOCOL"],
            GitEnvironment.allowedProtocols
        )
        let transports = GitEnvironment.allowedProtocols.split(separator: ":")
        for blocked in ["ext", "fd"] {
            XCTAssertFalse(transports.contains(Substring(blocked)), blocked)
        }
    }

    func testSECT10_01_ChildSeesOnlyTheAllowlist() async throws {
        let environment = GitEnvironment.environment(parent: hostileParent)
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: [],
                environment: environment,
                currentDirectory: nil,
                limits: .query
            )
        )
        let keys = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
        XCTAssertEqual(Set(keys), Set(environment.keys))
    }

    func testSECT10_02_PathIsFixed() {
        XCTAssertEqual(GitEnvironment.environment(parent: hostileParent)["PATH"], GitEnvironment.path)
        XCTAssertEqual(GitEnvironment.environment(parent: [:])["PATH"], GitEnvironment.path)
    }

    func testTrustedSSHCommandIsUsedWhenProvided() {
        let environment = GitEnvironment.environment(parent: [:], trustedSSHCommand: "ssh -i ~/.ssh/work")
        XCTAssertEqual(environment["GIT_SSH_COMMAND"], "ssh -i ~/.ssh/work")
    }

    func testCommonArgumentsMatchTheSecurityReview() {
        // Snapshot of security-review.md §3.1; change both together.
        XCTAssertEqual(
            GitEnvironment.commonArguments,
            [
                "--no-pager", "--no-optional-locks", "--literal-pathspecs",
                "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.askPass=",
                "-c", "protocol.ext.allow=never", "-c", "protocol.fd.allow=never", "-c", "core.alternateRefsCommand=",
                "-c", "log.showSignature=false", "-c", "gc.auto=0", "-c", "maintenance.auto=false",
                "-c", "diff.autoRefreshIndex=false", "-c", "color.ui=never", "-c", "diff.suppressBlankEmpty=false",
                "-c", "i18n.logOutputEncoding=UTF-8",
            ]
        )
    }

    func testArgumentOrder() {
        let environment = GitEnvironment(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            version: GitVersion(major: 2, minor: 50, patch: 1)
        )
        let arguments = environment.arguments(
            for: ["fetch", "--no-recurse-submodules", "origin"],
            neutralization: ["-c", "filter.lfs.clean="],
            fetchAuthentication: ["-c", "credential.helper="]
        )
        XCTAssertEqual(
            arguments,
            GitEnvironment.commonArguments + [
                "-c", "filter.lfs.clean=", "-c", "credential.helper=", "fetch", "--no-recurse-submodules", "origin",
            ]
        )
    }

    func testDiscoversTheRealGit() async throws {
        let environment = try await GitEnvironment.discover()
        XCTAssertTrue(environment.version.isSupported)
        XCTAssertTrue(environment.executable.path.hasSuffix("/usr/bin/git"))
        XCTAssertNotEqual(environment.executable.path, "/usr/bin/git", "the xcrun shim is bypassed")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: environment.executable.path))
    }

    func testRejectsAnOldGit() async throws {
        let fake = try executables.fakeDeveloperDirectory(versionLine: "git version 2.30.1")
        do {
            _ = try await GitEnvironment.discover(developerDirectory: { fake })
            XCTFail("expected unsupportedVersion")
        } catch let error as GitError {
            XCTAssertEqual(error, .unsupportedVersion(found: GitVersion(major: 2, minor: 30, patch: 1)))
        }
    }

    func testMissingDeveloperToolsIsExecutableNotFound() async {
        do {
            _ = try await GitEnvironment.discover(developerDirectory: { nil })
            XCTFail("expected executableNotFound")
        } catch let error as GitError {
            guard case .executableNotFound = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
