import Foundation
import XCTest

@testable import Overgrove

/// SEC tests for T1–T7 scenarios the `--malicious` fixture does not contain (security-review.md §2). Each builds a
/// small repository with an isolated HOME (`SecurityScenario`), runs the app's real path, and then a negative
/// control with plain git. Controls were measured with Apple Git 2.50.1 (#92).
final class ConfigExecutionScenarioTests: XCTestCase {
    private var executables: TestExecutables!
    private var scenario: SecurityScenario!

    override func setUp() async throws {
        executables = try TestExecutables()
        scenario = try await SecurityScenario.make(executables)
    }

    override func tearDown() {
        executables?.remove()
    }

    // MARK: Builders

    /// A repository with `files` committed on `main`.
    private func repository(_ name: String, files: [String: String]) async throws -> URL {
        let url = scenario.directory(name)
        try await scenario.plain(
            ["init", "-q", "-b", "main", url.path], in: executables.directory, requireSuccess: true)
        for (path, contents) in files {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        try await scenario.plain(["add", "-A"], in: url, requireSuccess: true)
        try await scenario.plain(["commit", "-q", "-m", "initial"], in: url, requireSuccess: true)
        return url
    }

    /// `super/` with `sub/` as a submodule. Returns the superproject and the submodule's git directory.
    private func superprojectWithSubmodule() async throws -> (superproject: URL, submoduleGitDir: URL) {
        let sub = try await repository("sub", files: ["a.dat": "a\n"])
        let superproject = try await repository("super", files: ["readme.txt": "super\n"])
        try await scenario.plain(["submodule", "-q", "add", sub.path, "sub"], in: superproject, requireSuccess: true)
        try await scenario.plain(["commit", "-q", "-m", "add submodule"], in: superproject, requireSuccess: true)
        return (superproject, superproject.appendingPathComponent(".git/modules/sub", isDirectory: true))
    }

    /// Makes git re-hash the file through its filter on the next status (content unchanged, mtime changed).
    private func touch(_ file: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_767_225_600)], ofItemAtPath: file.path)
    }

    private func writeAttributes(_ line: String, gitDirectory: URL) throws {
        let info = gitDirectory.appendingPathComponent("info", isDirectory: true)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try (line + "\n").write(to: info.appendingPathComponent("attributes"), atomically: true, encoding: .utf8)
    }

    private func statusArguments(dropping flag: String? = nil) throws -> [String] {
        try ReadOnlyGitCommand.status.subcommandArguments().filter { $0 != flag }
    }

    private func assertNoCanary(after action: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(scenario.canaries(), [], "\(action) ran a repository-configured program", file: file, line: line)
    }

    private func assertFired(_ id: String, _ action: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            scenario.canaries().contains(id), "control \(action): expected \(id), got \(scenario.canaries())",
            file: file, line: line)
    }

    // MARK: T1

    /// SEC-T1-02: `core.fsmonitor` in a submodule's configuration does not run when the app reads the superproject's
    /// status. Two layers stop it: `--ignore-submodules=dirty` (no recursion) and `-c core.fsmonitor=false`, which
    /// reaches the submodule's git through `GIT_CONFIG_PARAMETERS`. Plain git recurses and runs it.
    func testSECT1_02_SubmoduleFSMonitorDoesNotRun() async throws {
        let (superproject, submodule) = try await superprojectWithSubmodule()
        try await scenario.plain(
            ["--git-dir", submodule.path, "config", "core.fsmonitor", try scenario.payload("T1-sub", tail: "exit 1")],
            in: superproject, requireSuccess: true)

        _ = try await scenario.app(.status, in: superproject)
        assertNoCanary(after: "app status")
        // Second layer on its own: recursion allowed, the common arguments still disable fsmonitor in the submodule.
        _ = try await scenario.appArguments(
            try statusArguments(dropping: "--ignore-submodules=dirty"), in: superproject)
        assertNoCanary(after: "app arguments with recursion allowed")

        try await scenario.plain(try statusArguments(dropping: "--ignore-submodules=dirty"), in: superproject)
        assertFired("T1-sub", "status recursing into the submodule")
    }

    // MARK: T2

    /// SEC-T2-01 (`.git/hooks/`; the `core.hooksPath` route is in `ConfigExecutionFixtureTests`): fetch does not run
    /// a `reference-transaction` hook placed in the repository's hooks directory.
    func testSECT2_01_FetchRunsNoHookFromHooksDirectory() async throws {
        let repo = try await repository("repo", files: ["x.txt": "x\n"])
        let origin = scenario.directory("origin.git")
        try await scenario.plain(
            ["init", "-q", "--bare", origin.path], in: executables.directory, requireSuccess: true)
        try await scenario.plain(["remote", "add", "origin", origin.path], in: repo, requireSuccess: true)
        try await scenario.plain(["push", "-q", "origin", "main"], in: repo, requireSuccess: true)
        try await scenario.plain(["update-ref", "refs/heads/new", "refs/heads/main"], in: origin, requireSuccess: true)
        let hook = repo.appendingPathComponent(".git/hooks/reference-transaction")
        try FileManager.default.copyItem(atPath: try scenario.payload("T2-hooks-dir"), toPath: hook.path)

        _ = try await scenario.appFetch("origin", in: repo)
        assertNoCanary(after: "app fetch")
        // The fetch had a ref to update, so it did reach the point where the hook would run.
        try await scenario.plain(["rev-parse", "--verify", "refs/remotes/origin/new"], in: repo, requireSuccess: true)

        try await scenario.plain(
            ["-c", "core.hooksPath=/dev/null", "update-ref", "-d", "refs/remotes/origin/new"], in: repo,
            requireSuccess: true)
        try await scenario.plain(FetchCommand.fetch(remote: RemoteName("origin")!).subcommandArguments(), in: repo)
        assertFired("T2-hooks-dir", "plain fetch")
    }

    // MARK: T3

    /// SEC-T3-01 (`diff.<driver>.command`; textconv and `diff.external` are in `ConfigExecutionFixtureTests`).
    func testSECT3_01_DiffDriverCommandDoesNotRun() async throws {
        let repo = try await repository("repo", files: ["x.txt": "x\n"])
        try "changed\n".write(to: repo.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try writeAttributes("*.txt diff=evil", gitDirectory: repo.appendingPathComponent(".git"))
        try await scenario.config("diff.evil.command", try scenario.payload("T3-diff-command"), in: repo)

        let diff = ReadOnlyGitCommand.worktreeDiff(path: GitPath("x.txt"), staged: false)
        _ = try await scenario.app(diff, in: repo)
        assertNoCanary(after: "app worktree diff")

        try await scenario.plain(try diff.subcommandArguments().filter { $0 != "--no-ext-diff" }, in: repo)
        assertFired("T3-diff-command", "diff without --no-ext-diff")
    }

    // MARK: T4

    /// SEC-T4-01: a filter attached through a committed `.gitattributes` is neutralized; the common arguments alone
    /// would run it.
    func testSECT4_01_TrackedGitattributesFilterIsNeutralized() async throws {
        let repo = try await repository("repo", files: [".gitattributes": "*.dat filter=evil\n", "a.dat": "a\n"])
        try await scenario.config("filter.evil.clean", try scenario.payload("T4-gitattributes", tail: "cat"), in: repo)
        try touch(repo.appendingPathComponent("a.dat"))

        _ = try await scenario.app(.status, in: repo)
        assertNoCanary(after: "app status")

        let commonArgumentsOnly = RepoSafetyContext(
            inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil)
        _ = try? await scenario.client().run(.status, in: repo, safety: commonArgumentsOnly)
        assertFired("T4-gitattributes", "status without neutralization")
    }

    /// SEC-T4-03: with `required=true`, the app's status still succeeds and runs nothing, because the neutralization
    /// also sets `required=false`. Without that one argument, the emptied filter itself is fatal (security-review.md
    /// E6; it only shows on a file whose content is unchanged but whose stat changed, which status re-hashes).
    func testSECT4_03_RequiredFilterDoesNotBreakStatus() async throws {
        let repo = try await repository("repo", files: ["a.dat": "a\n"])
        try writeAttributes("*.dat filter=evil", gitDirectory: repo.appendingPathComponent(".git"))
        try await scenario.config("filter.evil.clean", try scenario.payload("T4-required", tail: "exit 1"), in: repo)
        try await scenario.config("filter.evil.required", "true", in: repo)
        try touch(repo.appendingPathComponent("a.dat"))

        let inspection = try await scenario.inspect(repo)
        XCTAssertTrue(inspection.neutralization.contains("filter.evil.required=false"))
        _ = try await scenario.app(.status, in: repo)
        assertNoCanary(after: "app status")

        // The neutralization minus `required=false`: status fails with "clean filter 'evil' failed".
        var withoutRequired: [String] = []
        var arguments = inspection.neutralization[...]
        while let first = arguments.first {
            let pair = Array(arguments.prefix(2))
            arguments = arguments.dropFirst(min(2, arguments.count))
            if first == "-c", pair.last == "filter.evil.required=false" { continue }
            withoutRequired += pair
        }
        let partial = RepoSafetyContext(
            inspectedNeutralization: withoutRequired, fetchAuthentication: [], trustedSSHCommand: nil)
        do {
            _ = try await scenario.client().run(.status, in: repo, safety: partial)
            XCTFail("without required=false the emptied required filter must be fatal (E6)")
        } catch GitError.nonZeroExit(_, let detail) {
            XCTAssertTrue(detail.text.contains("clean filter 'evil' failed"), detail.text)
        }
        assertNoCanary(after: "app status without required=false")

        let control = try await scenario.plain(try statusArguments(), in: repo)
        assertFired("T4-required", "plain status")
        XCTAssertNotEqual(control.termination, .exited(code: 0), "a failing required filter makes plain status fail")
    }

    /// SEC-T4-04 (end to end; the unit test is in `RepoConfigInspectorTests`): a driver name that cannot be
    /// neutralized blocks every query of the repository instead of running its filter.
    func testSECT4_04_UnneutralizableDriverBlocksQueries() async throws {
        let repo = try await repository("repo", files: ["a.dat": "a\n"])
        try writeAttributes("*.dat filter=bad+name", gitDirectory: repo.appendingPathComponent(".git"))
        try await scenario.config("filter.bad+name.clean", try scenario.payload("T4-bad-name", tail: "cat"), in: repo)
        try touch(repo.appendingPathComponent("a.dat"))

        let inspection = try await scenario.inspect(repo)
        XCTAssertTrue(inspection.report.isBlocked)
        XCTAssertNil(inspection.safetyContext)
        do {
            _ = try await scenario.app(.status, in: repo)
            XCTFail("a blocked repository must not be queried")
        } catch SecurityScenario.ScenarioError.blocked {}
        assertNoCanary(after: "blocked inspection")

        try await scenario.plain(try statusArguments(), in: repo)
        assertFired("T4-bad-name", "plain status")
    }

    /// SEC-T4-05: a filter defined in a submodule does not run from the superproject's status
    /// (`--ignore-submodules=dirty`). Plain recursion runs it; this was an open question in security-review.md §4.2.
    func testSECT4_05_SubmoduleFilterDoesNotRun() async throws {
        let (superproject, submodule) = try await superprojectWithSubmodule()
        try await scenario.plain(
            ["--git-dir", submodule.path, "config", "filter.evil.clean", try scenario.payload("T4-sub", tail: "cat")],
            in: superproject, requireSuccess: true)
        try writeAttributes("*.dat filter=evil", gitDirectory: submodule)
        try touch(superproject.appendingPathComponent("sub/a.dat"))

        _ = try await scenario.app(.status, in: superproject)
        assertNoCanary(after: "app status")

        // `--ignore-submodules=dirty` is the only layer: the inspector reads the superproject's configuration only,
        // so with every other app argument kept and just this flag removed, the submodule's filter runs.
        _ = try await scenario.appArguments(
            try statusArguments(dropping: "--ignore-submodules=dirty"), in: superproject)
        assertFired("T4-sub", "app arguments without --ignore-submodules=dirty")
        try scenario.clearCanaries()
        try touch(superproject.appendingPathComponent("sub/a.dat"))

        try await scenario.plain(try statusArguments(dropping: "--ignore-submodules=dirty"), in: superproject)
        assertFired("T4-sub", "status recursing into the submodule")
    }

    /// SEC-T4-05, worktree diff (#239): the unstaged diff of a submodule path makes git run `status` inside the
    /// submodule, with the submodule's own (never inspected) filter. `worktreeDiff` carries `--ignore-submodules=dirty`
    /// like status. The staged diff never looks inside; control: without the flag the unstaged diff runs the filter.
    func testSECT4_05_SubmoduleFilterDoesNotRunFromTheWorktreeDiff() async throws {
        let (superproject, submodule) = try await superprojectWithSubmodule()
        try await scenario.plain(
            [
                "--git-dir", submodule.path, "config", "filter.evil.clean",
                try scenario.payload("T4-sub-diff", tail: "cat"),
            ],
            in: superproject, requireSuccess: true)
        try writeAttributes("*.dat filter=evil", gitDirectory: submodule)
        for staged in [false, true] {
            try touch(superproject.appendingPathComponent("sub/a.dat"))
            _ = try await scenario.app(.worktreeDiff(path: GitPath("sub"), staged: staged), in: superproject)
            assertNoCanary(after: "app worktreeDiff sub (staged: \(staged))")
        }

        try touch(superproject.appendingPathComponent("sub/a.dat"))
        let unprotected = try ReadOnlyGitCommand.worktreeDiff(path: GitPath("sub"), staged: false)
            .subcommandArguments().filter { $0 != "--ignore-submodules=dirty" }
        _ = try await scenario.appArguments(unprotected, in: superproject)
        assertFired("T4-sub-diff", "app worktreeDiff arguments without --ignore-submodules=dirty")
    }

    /// SEC-T4-05, base comparison (#157): comparing the working tree diffs into submodules as well, and git would run
    /// `status` inside one to see whether it is dirty, with the submodule's own (never inspected) filter. The compare
    /// commands carry `--ignore-submodules=dirty` like status; without it the submodule's filter runs.
    func testSECT4_05_SubmoduleFilterDoesNotRunFromTheBaseComparison() async throws {
        let (superproject, submodule) = try await superprojectWithSubmodule()
        try await scenario.plain(["branch", "base"], in: superproject, requireSuccess: true)
        try await scenario.plain(
            [
                "--git-dir", submodule.path, "config", "filter.evil.clean",
                try scenario.payload("T4-sub-cmp", tail: "cat"),
            ],
            in: superproject, requireSuccess: true)
        try writeAttributes("*.dat filter=evil", gitDirectory: submodule)
        let base = FullRefName("refs/heads/base")!
        let commands: [ReadOnlyGitCommand] = [
            .compareFiles(base: base, includeWorkingTree: true),
            .comparePatch(base: base, path: GitPath("sub"), includeWorkingTree: true),
        ]
        for command in commands {
            try touch(superproject.appendingPathComponent("sub/a.dat"))
            _ = try await scenario.app(command, in: superproject)
            assertNoCanary(after: "app \(command)")
        }

        try touch(superproject.appendingPathComponent("sub/a.dat"))
        let unprotected = try commands[0].subcommandArguments().filter { $0 != "--ignore-submodules=dirty" }
        _ = try await scenario.appArguments(unprotected, in: superproject)
        assertFired("T4-sub-cmp", "app comparison arguments without --ignore-submodules=dirty")
    }

    // MARK: T6 (credential fill with the app's fetch arguments stands in for HTTP authentication)
    //
    // Like the app, the app-path runs read system configuration, so a system helper (Apple's `osxkeychain`) also runs
    // a lookup for `example.invalid`. That is read-only and the app's real behavior; the assertions only concern the
    // helpers these tests plant.

    private let credentialRequest = "protocol=https\nhost=example.invalid\npath=overgrove.git\n\n"

    /// SEC-T6-01: a repository-local generic `credential.helper` does not run.
    func testSECT6_01_LocalGenericHelperDoesNotRun() async throws {
        let repo = try await repository("repo", files: ["x.txt": "x\n"])
        try await scenario.config("credential.helper", try scenario.payload("T6-local-generic"), in: repo)

        _ = try await scenario.appCredentialFill(in: repo, input: credentialRequest)
        assertNoCanary(after: "app credential fill")

        try await scenario.plain(["credential", "fill"], in: repo, stdin: credentialRequest)
        assertFired("T6-local-generic", "plain credential fill")
    }

    /// SEC-T6-02: repository-local URL-specific and wildcard helpers do not run. A trusted global helper (recorded
    /// outside `canary/`) proves the app's run did reach the helper stage.
    func testSECT6_02_LocalURLAndWildcardHelpersDoNotRun() async throws {
        let repo = try await repository("repo", files: ["x.txt": "x\n"])
        let trustedRecords = executables.directory.appendingPathComponent("trusted", isDirectory: true)
        let trusted = try executables.canaryPayload("T6-trusted", canary: trustedRecords)
        try await scenario.plain(
            ["config", "--global", "credential.helper", trusted.path], in: repo, requireSuccess: true)
        try await scenario.config(
            "credential.https://example.invalid.helper", try scenario.payload("T6-local-url"), in: repo)
        try await scenario.config(
            "credential.https://*.invalid.helper", try scenario.payload("T6-local-wildcard"), in: repo)

        _ = try await scenario.appCredentialFill(in: repo, input: credentialRequest)
        assertNoCanary(after: "app credential fill")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: trustedRecords.appendingPathComponent("T6-trusted").path),
            "the trusted helper must run, or the app's run never reached the helper stage")

        try await scenario.plain(["credential", "fill"], in: repo, stdin: credentialRequest)
        assertFired("T6-local-url", "plain credential fill")
        assertFired("T6-local-wildcard", "plain credential fill")
    }

    /// SEC-T6-03: trusted global helpers still run in their original configuration order (written URL-specific
    /// first, so an implementation that always re-inserts the generic key first would fail), while the repository's
    /// own helper does not.
    func testSECT6_03_TrustedGlobalHelpersRunInOrder() async throws {
        let repo = try await repository("repo", files: ["x.txt": "x\n"])
        let order = scenario.canary.appendingPathComponent("T6-order").path
        func trusted(_ id: String) throws -> String {
            try scenario.payload(id, tail: "printf '%s\\n' \(id) >> '\(order)'")
        }
        try await scenario.plain(
            ["config", "--global", "credential.https://example.invalid.helper", try trusted("T6-trusted-url")],
            in: repo, requireSuccess: true)
        try await scenario.plain(
            ["config", "--global", "credential.helper", try trusted("T6-trusted-generic")], in: repo,
            requireSuccess: true)
        try await scenario.config("credential.helper", try scenario.payload("T6-local-generic"), in: repo)

        _ = try await scenario.appCredentialFill(in: repo, input: credentialRequest)
        XCTAssertEqual(scenario.records("T6-order"), ["T6-trusted-url", "T6-trusted-generic"])
        XCTAssertFalse(scenario.canaries().contains("T6-local-generic"), "the repository's helper must not run")
    }

    // MARK: T7

    /// SEC-T7-01 (fileHistory; graphPage and commitMeta are in `ConfigExecutionFixtureTests`): the history of a file
    /// changed by a fake-signed commit does not run `gpg.program`.
    func testSECT7_01_FileHistoryRunsNoGPG() async throws {
        let repo = try await repository("repo", files: ["a.txt": "a\n"])
        try "signed change\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await scenario.plain(["add", "a.txt"], in: repo, requireSuccess: true)
        let tree = try await output(["write-tree"], in: repo)
        let parent = try await output(["rev-parse", "HEAD"], in: repo)
        let commit = """
            tree \(tree)
            parent \(parent)
            author Alice Example <alice@example.invalid> 1767225600 +0000
            committer Alice Example <alice@example.invalid> 1767225600 +0000
            gpgsig -----BEGIN PGP SIGNATURE-----
             \n fixture-not-a-real-signature
             -----END PGP SIGNATURE-----

            signed change

            """
        let signed = try await scenario.plain(
            ["hash-object", "-t", "commit", "-w", "--stdin"], in: repo, stdin: commit, requireSuccess: true)
        let oid = String(decoding: signed.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try await scenario.plain(["update-ref", "refs/heads/main", oid], in: repo, requireSuccess: true)
        try await scenario.config("gpg.program", try scenario.payload("T7-history", tail: "exit 1"), in: repo)
        try await scenario.config("log.showSignature", "true", in: repo)

        let history = ReadOnlyGitCommand.fileHistory(path: GitPath("a.txt"), limit: 10)
        let result = try await scenario.app(history, in: repo)
        XCTAssertEqual(try LogParser.parseGraph(result.stdout).commits.first?.oid.hex, oid)
        assertNoCanary(after: "app file history")

        try await scenario.plain(try history.subcommandArguments(), in: repo)
        assertFired("T7-history", "plain file history")
    }

    private func output(_ arguments: [String], in repo: URL) async throws -> String {
        let result = try await scenario.plain(arguments, in: repo, requireSuccess: true)
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
