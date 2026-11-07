import Foundation
import XCTest

@testable import Overgrove

/// SEC-T2-03…05: hooks defined in configuration (`hook.<name>.command` / `.event`, git 2.54+, #354,
/// security-review.md T2). `core.hooksPath=/dev/null` covers only the hooks directory, so each repository-controlled
/// hook name is turned off with `-c hook.<name>.enabled=false`.
final class ConfigHookSecurityTests: XCTestCase {
    // MARK: - Inspection

    private func entry(
        _ scope: ConfigEntry.Scope, _ subsection: String?, _ variable: String, _ value: String = "x"
    ) -> ConfigEntry {
        ConfigEntry(scope: scope, section: "hook", subsection: subsection, variable: variable, value: value)
    }

    private func inspect(_ entries: [ConfigEntry]) -> RepoConfigInspection {
        RepoConfigInspector.inspect(ConfigParser.Listing(entries: entries, isPartial: false))
    }

    private func hookArguments(_ inspection: RepoConfigInspection) -> [String] {
        var pairs: [String] = []
        var index = 0
        while index + 1 < inspection.neutralization.count {
            if inspection.neutralization[index + 1].hasPrefix("hook.") {
                pairs.append(inspection.neutralization[index + 1])
            }
            index += 2
        }
        return pairs
    }

    func testRepositoryHooksAreNeutralizedByName() {
        let inspection = inspect([
            entry(.local, "lint", "command"), entry(.local, "lint", "event", "reference-transaction"),
            entry(.worktree, "a.b c", "event", "post-checkout"),
            entry(.local, "UPPER", "enabled", "true"),
            // A repository can attach a trusted global hook to another event: the name is turned off too.
            entry(.global, "shared", "command"), entry(.local, "shared", "event", "reference-transaction"),
            // The user's own hooks are trusted.
            entry(.global, "mine", "command"), entry(.system, "theirs", "command"),
        ])
        XCTAssertEqual(
            hookArguments(inspection),
            [
                "hook.lint.enabled=false", "hook.a.b c.enabled=false", "hook.UPPER.enabled=false",
                "hook.shared.enabled=false",
            ])
        XCTAssertNil(inspection.fetchBlockingReason)
        XCTAssertFalse(inspection.hasUnneutralizedHooks)
        let findings = inspection.report.findings
        XCTAssertEqual(findings.count, 5)
        XCTAssertTrue(findings.allSatisfy { $0.threat == "T2" && $0.handling == .neutralized })
        XCTAssertNotNil(inspection.safetyContext)
    }

    func testAKeyWithoutANameIsReportedOnly() {
        let inspection = inspect([entry(.local, nil, "command")])
        XCTAssertEqual(hookArguments(inspection), [])
        XCTAssertEqual(inspection.report.findings.map(\.handling), [.reported])
        XCTAssertNil(inspection.fetchBlockingReason)
    }

    /// SEC-T2-05: a hook name that cannot be spliced into `-c hook.<name>.enabled=false`, or more hooks than
    /// `maximumNeutralizedHooks`, disables fetch (fail closed). Queries go on: they run no hook (SEC-T2-04).
    func testSECT2_05_UnneutralizableHooksDisableFetch() {
        for name in [
            "a=b", "tab\there", "bell\u{7}", "del\u{7F}", "c1\u{85}", "lossy\u{FFFD}", "",
            String(repeating: "n", count: 257),
        ] {
            let inspection = inspect([entry(.local, name, "command")])
            XCTAssertTrue(inspection.hasUnneutralizedHooks, name.debugDescription)
            XCTAssertNotNil(inspection.fetchBlockingReason, name.debugDescription)
            XCTAssertFalse(inspection.report.isBlocked, "queries still run")
            XCTAssertNil(hookArguments(inspection).first { $0.contains(name) && !name.isEmpty })
        }

        let many = (0...RepoConfigInspector.maximumNeutralizedHooks).map { entry(.local, "h\($0)", "command") }
        let inspection = inspect(many)
        XCTAssertEqual(hookArguments(inspection).count, RepoConfigInspector.maximumNeutralizedHooks)
        XCTAssertTrue(inspection.hasUnneutralizedHooks)
        XCTAssertNotNil(inspection.safetyContext?.fetchBlockingReason)

        let atLimit = inspect(Array(many.dropLast()))
        XCTAssertFalse(atLimit.hasUnneutralizedHooks)
        XCTAssertNil(atLimit.fetchBlockingReason)
    }

    func testNeutralizableHookNames() {
        for name in ["lint", "a.b", "with space", "ünï", "a/b:c", "UPPER", String(repeating: "n", count: 256)] {
            XCTAssertTrue(ConfigParser.isNeutralizableHookName(name), name)
        }
    }

    // MARK: - Fixture (real git)

    private func harness() async throws -> CanaryHarness {
        try await CanaryHarness.make(fixture: try await makeFixture(malicious: true))
    }

    private static func droppingHookArguments(_ arguments: [String]) -> [String] {
        var kept: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "-c", index + 1 < arguments.count, arguments[index + 1].hasPrefix("hook.") {
                index += 2
                continue
            }
            kept.append(arguments[index])
            index += 1
        }
        return kept
    }

    /// SEC-T2-03: the app's fetch of the `--malicious` fixture runs none of its config-defined hooks, and on git that
    /// has them, the same fetch with only the hook neutralization removed (`core.hooksPath=/dev/null` and every other
    /// argument kept) runs one.
    func testSECT2_03_FetchRunsNoConfigDefinedHook() async throws {
        let harness = try await harness()
        XCTAssertTrue(harness.safety.neutralization.contains("hook.fixture.enabled=false"))
        let queries = try await harness.queries()
        let fetch = try XCTUnwrap(queries.first { $0.label.hasPrefix("fetch origin") })
        try await harness.runHardened(fetch)
        harness.fixture.assertNoCanaries(after: "app fetch origin")
        try await harness.runHardenedSetup(["rev-parse", "--verify", "refs/remotes/origin/feat/remote-only"])

        guard harness.environment.version >= GitVersion.configDefinedHooks else { return }
        try await harness.forgetRemoteOnlyBranch()
        try await harness.withNeutralization(Self.droppingHookArguments).runHardened(fetch)
        XCTAssertEqual(
            harness.fixture.canaries(), ["T2-config-hook"],
            "control: only the hook neutralization stops it on git \(harness.environment.version)")
    }

    /// SEC-T2-04 (measurement): no query the app runs triggers a config-defined hook, even without the hook
    /// neutralization. So a hook Overgrove cannot neutralize disables fetch only (SEC-T2-05). The fixture's hook
    /// listens on every event git documents.
    func testSECT2_04_QueriesRunNoConfigDefinedHookEvenUnneutralized() async throws {
        let harness = try await harness()
        let unneutralized = harness.withNeutralization(Self.droppingHookArguments)
        XCTAssertFalse(unneutralized.safety.neutralization.contains { $0.hasPrefix("hook.") })
        var snapshot = harness.fixture.canaryRecords()
        for query in try await harness.queries() {
            guard case .query = query.kind else { continue }
            try await unneutralized.runHardened(query)
            snapshot = harness.fixture.assertNoNewCanaries(since: snapshot, after: query.label)
        }
    }
}
