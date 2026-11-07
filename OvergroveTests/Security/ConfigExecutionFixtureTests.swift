import Foundation
import XCTest

@testable import Overgrove

/// SEC tests for T1–T4, T7, T8 against the `--malicious` fixture (security-review.md §2, fixtures.md §8).
///
/// Each test runs the app's real path (`CanaryHarness`: `RepoConfigInspector` → `RepoSafetyContext` → `GitClient`)
/// and then a negative control showing the same vector is live without Overgrove's hardening. Expected control
/// canaries were measured with Apple Git 2.50.1 (fixtures.md §8.2, §9.1).
final class ConfigExecutionFixtureTests: XCTestCase {
    private func harness() async throws -> CanaryHarness {
        try await CanaryHarness.make(fixture: try await makeFixture(malicious: true))
    }

    private func query(_ prefix: String, in queries: [CanaryHarness.Query]) throws -> CanaryHarness.Query {
        try XCTUnwrap(queries.first { $0.label.hasPrefix(prefix) }, prefix)
    }

    private func assertFired(
        _ expected: Set<String>,
        _ fixture: FixtureRepo,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let fired = Set(fixture.canaries())
        XCTAssertTrue(
            expected.isSubset(of: fired), "control \(what): expected \(expected.sorted()), got \(fired.sorted())",
            file: file, line: line)
    }

    // MARK: T1

    /// SEC-T1-01: status of the malicious fixture runs no `core.fsmonitor` program.
    func testSECT1_01_StatusRunsNoFSMonitor() async throws {
        let harness = try await harness()
        let status = try query("status (main", in: try await harness.queries())
        try await harness.runHardened(status)
        harness.fixture.assertNoCanaries(after: "app status")

        _ = try await harness.runPlain(status)
        assertFired(["T1-fsmonitor"], harness.fixture, "plain status")
    }

    // MARK: T2

    /// SEC-T2-01: fetch, which updates refs, runs no hook from `core.hooksPath` (the fixture's planted hooks).
    /// `.git/hooks/` is covered by `ConfigExecutionScenarioTests`.
    func testSECT2_01_FetchRunsNoHook() async throws {
        let harness = try await harness()
        let fetch = try query("fetch origin", in: try await harness.queries())
        try await harness.runHardened(fetch)
        harness.fixture.assertNoCanaries(after: "app fetch origin")

        try await harness.forgetRemoteOnlyBranch()
        harness.fixture.assertNoCanaries(after: "setup")
        _ = try await harness.runPlain(fetch)
        assertFired(["T2-hook-reference-transaction"], harness.fixture, "plain fetch")
    }

    // MARK: T3

    /// SEC-T3-01 (textconv and `diff.external`; `diff.<d>.command` is in `ConfigExecutionScenarioTests`): every
    /// patch the app can show runs neither.
    func testSECT3_01_PatchesRunNoTextconvOrExternalDiff() async throws {
        let harness = try await harness()
        let queries = try await harness.queries()
        for prefix in ["worktreeDiff unstaged", "worktreeDiff staged", "untrackedPreview", "stashPatch", "commitPatch"]
        {
            for patch in queries.filter({ $0.label.hasPrefix(prefix) }) {
                try await harness.runHardened(patch)
                harness.fixture.assertNoCanaries(after: "app \(patch.label)")
            }
        }

        let diff = try query("worktreeDiff unstaged", in: queries)
        _ = try await harness.runPlain(diff, dropping: ["--no-ext-diff", "--no-textconv"])
        assertFired(["T3-external-diff"], harness.fixture, "diff without --no-ext-diff")
        try harness.fixture.clearCanaries()
        _ = try await harness.runPlain(diff, dropping: ["--no-textconv"])
        assertFired(["T3-textconv"], harness.fixture, "diff without --no-textconv")
    }

    // MARK: T4

    /// SEC-T4-02: a filter attached through `.git/info/attributes` (the fixture's route) is neutralized, and the
    /// common arguments alone would not stop it.
    func testSECT4_02_InfoAttributesFilterIsNeutralized() async throws {
        let harness = try await harness()
        let status = try query("status (main", in: try await harness.queries())
        try await harness.runHardened(status)
        harness.fixture.assertNoCanaries(after: "app status")
        XCTAssertTrue(harness.safety.neutralization.contains("filter.fixture.clean="))
        XCTAssertTrue(harness.safety.neutralization.contains("filter.fixtureproc.process="))

        let commonArgumentsOnly = RepoSafetyContext(
            inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil)
        _ = try? await harness.client.run(.status, in: harness.fixture.repository, safety: commonArgumentsOnly)
        XCTAssertTrue(
            Set(harness.fixture.canaries()).intersection(["T4-filter-clean", "T4-filter-process"]).count > 0,
            "control without neutralization: \(harness.fixture.canaries())")
    }

    // MARK: T7

    /// SEC-T7-01 (graphPage, commitMeta; fileHistory is in `ConfigExecutionScenarioTests`): the fake-signed commit
    /// does not make the app run `gpg.program`.
    func testSECT7_01_GraphAndCommitMetaRunNoGPG() async throws {
        let harness = try await harness()
        let queries = try await harness.queries()
        let graph = try query("graphPage", in: queries)
        let meta = try query("commitMeta malicious/signed", in: queries)
        for item in [graph, meta] {
            try await harness.runHardened(item)
            harness.fixture.assertNoCanaries(after: "app \(item.label)")
        }

        for item in [graph, meta] {
            try harness.fixture.clearCanaries()
            _ = try await harness.runPlain(item)
            assertFired(["T7-gpg-program"], harness.fixture, "plain \(item.label)")
        }
    }

    // MARK: T8

    /// SEC-T8-01: fetch with the app's arguments and environment starts neither `maintenance run` nor `gc --auto`
    /// (judged by `GIT_TRACE`, fixtures.md §8.3; the trace variable is a test-only addition), while plain fetch does.
    func testSECT8_01_FetchStartsNoAutoMaintenance() async throws {
        let harness = try await harness()
        let trace = harness.fixture.container.appendingPathComponent("trace-app.txt")
        let fetch = FetchCommand.fetch(remote: try XCTUnwrap(RemoteName("origin")))
        var environment = GitEnvironment.environment(
            parent: harness.fixture.environment, trustedSSHCommand: harness.safety.trustedSSHCommand)
        environment["GIT_TRACE"] = trace.path
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: harness.environment.executable,
                arguments: harness.environment.arguments(
                    for: fetch.subcommandArguments(),
                    neutralization: harness.safety.neutralization,
                    fetchAuthentication: harness.safety.fetchAuthentication),
                environment: environment,
                currentDirectory: harness.fixture.repository,
                limits: .fetch
            )
        )
        XCTAssertTrue(result.succeeded, String(decoding: result.stderr, as: UTF8.self))
        let appTrace = try String(contentsOf: trace, encoding: .utf8)
        XCTAssertTrue(appTrace.contains("fetch"), "the trace was written")
        for child in ["maintenance run", "gc --auto"] {
            XCTAssertFalse(appTrace.contains(child), "app fetch started \(child)")
        }
        harness.fixture.assertNoCanaries(after: "app fetch with GIT_TRACE")

        // Control: plain git, same subcommand, with work to do.
        try await harness.forgetRemoteOnlyBranch()
        let plainTrace = harness.fixture.container.appendingPathComponent("trace-plain.txt")
        _ = try await ProcessRunner().run(
            ProcessRequest(
                executable: harness.environment.executable,
                arguments: fetch.subcommandArguments(),
                environment: [
                    "HOME": harness.fixture.home.path, "PATH": GitEnvironment.path, "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_TRACE": plainTrace.path,
                ],
                currentDirectory: harness.fixture.repository,
                limits: .fetch
            )
        )
        let controlTrace = try String(contentsOf: plainTrace, encoding: .utf8)
        XCTAssertTrue(controlTrace.contains("maintenance run"), "control: plain fetch should start auto maintenance")
    }
}
