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
            // Canonically equivalent but different bytes: git runs both, so both are turned off.
            entry(.local, "\u{E9}", "command"), entry(.local, "e\u{301}", "command"),
            entry(.worktree, "a.b c", "event", "post-checkout"),
            entry(.local, "UPPER", "enabled", "true"),
            // A repository can attach a trusted global hook to another event: the name is turned off too.
            entry(.global, "shared", "command"), entry(.local, "shared", "event", "reference-transaction"),
            // The user's own hooks are trusted.
            entry(.global, "mine", "command"), entry(.system, "theirs", "command"),
        ])
        // Compared as bytes: `[String]` equality would treat the two spellings of é as one.
        XCTAssertEqual(
            hookArguments(inspection).map { Array($0.utf8) },
            [
                "hook.lint.enabled=false", "hook.\u{E9}.enabled=false", "hook.e\u{301}.enabled=false",
                "hook.a.b c.enabled=false", "hook.UPPER.enabled=false", "hook.shared.enabled=false",
            ].map { Array($0.utf8) })
        XCTAssertNil(inspection.fetchBlockingReason)
        XCTAssertFalse(inspection.hasUnneutralizedHooks)
        let findings = inspection.report.findings
        XCTAssertEqual(findings.count, 7)
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
    /// `maximumNeutralizedHooks`, stops queries and fetch (fail closed), as for filter drivers.
    func testSECT2_05_UnneutralizableHooksStopEverything() {
        for name in [
            "a=b", "tab\there", "bell\u{7}", "del\u{7F}", "c1\u{85}", "lossy\u{FFFD}", "",
            String(repeating: "n", count: 257),
        ] {
            let inspection = inspect([entry(.local, name, "command")])
            XCTAssertTrue(inspection.hasUnneutralizedHooks, name.debugDescription)
            XCTAssertTrue(inspection.report.isBlocked, name.debugDescription)
            XCTAssertNil(inspection.safetyContext, "nothing runs")
            XCTAssertNil(hookArguments(inspection).first { $0.contains(name) && !name.isEmpty })
        }

        let many = (0...RepoConfigInspector.maximumNeutralizedHooks).map { entry(.local, "h\($0)", "command") }
        let inspection = inspect(many)
        XCTAssertEqual(hookArguments(inspection).count, RepoConfigInspector.maximumNeutralizedHooks)
        XCTAssertTrue(inspection.hasUnneutralizedHooks)
        XCTAssertNil(inspection.safetyContext)

        let atLimit = inspect(Array(many.dropLast()))
        XCTAssertFalse(atLimit.hasUnneutralizedHooks)
        XCTAssertNotNil(atLimit.safetyContext)
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
    /// neutralization: for queries the neutralization is defense in depth. The fixture's hook listens on every event
    /// git documents.
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

    /// SEC-T2-06: hook names of many shapes, written into the configuration file as bytes (as a hostile repository
    /// would, past `git config`'s own Unicode handling), are all turned off: punctuation, surrounding spaces,
    /// non-ASCII, a canonically equivalent pair, and one the repository itself marks `enabled = true`.
    func testSECT2_06_EveryNameShapeIsNeutralized() async throws {
        let source = try await GitTestRepository.make()
        defer { source.remove() }
        try await source.git(["commit", "-q", "--allow-empty", "-m", "one"])
        let local = try await GitTestRepository.make()
        defer { local.remove() }
        try await local.git(["remote", "add", "origin", source.root.path])
        let canary = local.root.deletingLastPathComponent()
            .appendingPathComponent("overgrove-hook-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: canary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: canary) }

        let names = [
            "plain", "a.b", "with space", " lead", "trail ", "\u{FC}n\u{EF}", "\u{E9}", "e\u{301}", "q'uote", "bang!",
            #"back\slash"#, #"dq""#, "hash#", "semi;", "bidi\u{202E}x", "UPPER", "a/b:c", "enabled-true",
        ]
        var config = ""
        for (index, name) in names.enumerated() {
            // Inside a quoted subsection only `\` and `"` need escaping.
            let quoted = name.replacingOccurrences(of: #"\"#, with: #"\\"#).replacingOccurrences(
                of: #"""#, with: #"\""#)
            config += "[hook \"\(quoted)\"]\n\tcommand = : > '\(canary.path)/h\(index)'\n"
            config += "\tevent = reference-transaction\n"
            if name == "enabled-true" { config += "\tenabled = true\n" }
        }
        let file = try FileHandle(forWritingTo: local.root.appendingPathComponent(".git/config"))
        try file.seekToEnd()
        try file.write(contentsOf: Data(config.utf8))
        try file.close()

        let listing = try await GitClient(environment: local.environment)
            .run(.configList, in: local.root, safety: .preInspection)
        let inspection = RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout))
        let safety = try XCTUnwrap(inspection.safetyContext, "\(inspection.report)")
        XCTAssertEqual(hookArguments(inspection).count, names.count)
        let repository = Repository(
            rootURL: local.root, commonGitDirectoryURL: local.root.appendingPathComponent(".git"), isBare: false)
        let client = GitClient(environment: local.environment)
        _ = try await client.fetch(.fetch(remote: RemoteName("origin")!), in: repository, safety: safety)
        let fetched = try await local.git(["for-each-ref", "refs/remotes/origin"])
        XCTAssertFalse(fetched.stdout.isEmpty, "the fetch updated refs, so the event happened")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: canary.path), [])

        guard local.environment.version >= GitVersion.configDefinedHooks else { return }
        // Setup git has no hook neutralization, so this ref update runs the hooks itself: clear what it wrote, so the
        // control below is judged on its own.
        try await local.git(["update-ref", "-d", "refs/remotes/origin/main"])
        for name in try FileManager.default.contentsOfDirectory(atPath: canary.path) {
            try FileManager.default.removeItem(at: canary.appendingPathComponent(name))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: canary.path), [])
        let control = RepoSafetyContext(
            inspectedNeutralization: Self.droppingHookArguments(safety.neutralization),
            fetchAuthentication: safety.fetchAuthentication, trustedSSHCommand: safety.trustedSSHCommand,
            fetchableRemotes: safety.fetchableRemotes)
        _ = try await client.fetch(.fetch(remote: RemoteName("origin")!), in: repository, safety: control)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: canary.path)),
            Set(names.indices.map { "h\($0)" }), "control: every hook runs without its argument")
    }
}
