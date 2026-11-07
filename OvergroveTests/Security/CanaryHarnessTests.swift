import Foundation
import XCTest

@testable import Overgrove

/// The canary harness against the `--malicious` fixture (docs/testing/fixtures.md §8, INT-19).
///
/// The full SEC-Tn matrix (#92, #93) builds on this; here every allowlisted query runs once with a representative
/// target, and a negative control proves the payloads still fire without Overgrove's hardening.
final class CanaryHarnessTests: XCTestCase {
    /// INT-19: every `ReadOnlyGitCommand` case and `fetch origin`, run exactly as the app runs them, leave `canary/`
    /// empty. Each command is checked on its own so a failure names the command and the threat.
    func testINT19_EveryAppCommandRunsNoRepositoryConfiguredProgram() async throws {
        let fixture = try await makeFixture(malicious: true)
        // A missing canary/ would make every payload's write fail silently, so check it before anything runs.
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.canary.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(fixture.canaries(), [])

        let harness = try await CanaryHarness.make(fixture: fixture)
        fixture.assertNoCanaries(after: "configList + RepoConfigInspector")
        XCTAssertFalse(harness.inspection.neutralization.isEmpty, "the fixture's filters must be neutralized")

        let queries = try await harness.queries()
        fixture.assertNoCanaries(after: "resolving fixture revisions")

        let covered = Set(
            queries.compactMap { query -> CanaryHarness.CaseName? in
                guard case .query(let command) = query.kind else { return nil }
                return CanaryHarness.caseName(command)
            })
        XCTAssertEqual(covered, Set(CanaryHarness.CaseName.allCases), "every ReadOnlyGitCommand case must run")
        XCTAssertTrue(queries.contains { if case .fetch = $0.kind { true } else { false } }, "fetch is exercised")

        // Judged by difference, never by deleting: each command is blamed only for what it added, and a late write
        // still shows up at the next check or the final one.
        var snapshot = fixture.canaryRecords()
        for query in queries {
            do {
                try await harness.runHardened(query)
            } catch {
                XCTFail("\(query) failed, so it may not have reached the payload's code path: \(error)")
            }
            snapshot = fixture.assertNoNewCanaries(since: snapshot, after: query.label)
        }
        fixture.assertNoCanaries(after: "all commands")
    }

    /// Negative control: the app's own subcommand arguments, run with plain git (no common `-c` arguments, no
    /// neutralization, no environment allowlist), do run the payloads. If this stops failing the fixture is broken
    /// and INT-19 proves nothing. Rows that drop subcommand-level flags prove those flags are what stop T3, the
    /// smudge filter, and the uploadpack override. Expected canaries were measured with Apple Git 2.50.1 and match
    /// fixtures.md §8.2 (M01, M04, M12, M20, M23).
    func testNegativeControl_PayloadsFireWithoutHardening() async throws {
        let fixture = try await makeFixture(malicious: true)
        let harness = try await CanaryHarness.make(fixture: fixture)
        let queries = try await harness.queries()

        // Config-defined hooks exist from git 2.54 (#354); older git ignores the fixture's `hook.*` keys.
        let configHooks: Set<String> =
            harness.environment.version >= GitVersion.configDefinedHooks ? ["T2-config-hook"] : []
        let controls: [(label: String, dropping: Set<String>, expected: Set<String>)] = [
            // The failing process filter aborts plain status, so whether the clean filter ran first depends on
            // file order; `T4-filter-clean` is proven by the worktreeDiff row instead.
            ("status (main worktree", [], ["T1-fsmonitor", "T4-filter-process"]),
            ("worktreeDiff unstaged", [], ["T1-fsmonitor", "T4-filter-clean"]),
            ("worktreeDiff unstaged", ["--no-ext-diff", "--no-textconv"], ["T3-external-diff", "T4-filter-smudge"]),
            ("worktreeDiff unstaged", ["--no-textconv"], ["T3-textconv", "T4-filter-smudge"]),
            ("worktreeNumstat unstaged", [], ["T1-fsmonitor", "T4-filter-clean"]),
            ("graphPage", [], ["T7-gpg-program"]),
            ("fetch origin", [], Set(["T5-alternateRefsCommand", "T2-hook-reference-transaction"]).union(configHooks)),
            ("fetch origin", ["--upload-pack=git-upload-pack"], ["T5-uploadpack"]),
        ]
        for control in controls {
            let query = try XCTUnwrap(queries.first { $0.label.hasPrefix(control.label) }, control.label)
            try fixture.clearCanaries()
            let result = try await harness.runPlain(query, dropping: control.dropping)
            let fired = Set(fixture.canaries())
            XCTAssertTrue(
                control.expected.isSubset(of: fired),
                "plain \(query) without \(control.dropping.sorted()) should run \(control.expected.sorted()) "
                    + "but ran \(fired.sorted()) (exit \(result.termination))")
        }
    }

    /// Every canary the fixture plants is in `Canary.all` and vice versa. Reads files only; runs no git command.
    func testCatalogMatchesTheFixturePayloads() async throws {
        let fixture = try await makeFixture(malicious: true)
        var planted = Set<String>()
        let marker = fixture.canary.path + "/"
        var sources = [fixture.repository.appendingPathComponent(".git/config")]
        let enumerator = FileManager.default.enumerator(
            at: fixture.payloads, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { sources.append(url) }
        }
        XCTAssertGreaterThan(sources.count, Canary.hookNames.count, "payload scripts were found")
        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            var rest = text[...]
            while let range = rest.range(of: marker) {
                let id = rest[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" }
                if !id.isEmpty { planted.insert(String(id)) }
                rest = rest[range.upperBound...]
            }
        }
        XCTAssertEqual(planted, Set(Canary.all.map(\.id)))
        XCTAssertEqual(Canary.all.count, Set(Canary.all.map(\.id)).count, "canary IDs are unique")
    }

    func testFailureMessageNamesActionThreatAndArguments() {
        let message = FixtureRepo.canaryFailureMessage(
            action: "status",
            records: ["T1-fsmonitor": "2 0\n2 0\n", "T5-ext-transport": "", "T9-new": "x\n"]
        )
        XCTAssertTrue(message.hasPrefix("status ran 3 repository-configured program(s):"), message)
        XCTAssertTrue(message.contains("T1-fsmonitor: T1, core.fsmonitor — ran 2×, args: \"2 0\\n2 0\\n\""), message)
        XCTAssertTrue(message.contains("T5-ext-transport: T5, ext:: remote transport — ran 1×"), message)
        XCTAssertTrue(message.contains("T9-new: unknown canary"), message)
    }

    /// The assertion really fails when a canary exists (otherwise INT-19 could never fail).
    func testAssertionFailsWhenACanaryExists() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("overgrove-canary-\(UUID().uuidString)", isDirectory: true)
        let fixture = FixtureRepo(container: container, root: container, home: container, isMalicious: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: fixture.canary, withIntermediateDirectories: true)

        fixture.assertNoCanaries(after: "empty canary directory")
        let planted = fixture.canary.appendingPathComponent("T7-gpg-program")
        try "args\n".write(to: planted, atomically: true, encoding: .utf8)
        XCTExpectFailure("a canary file must fail the check") {
            fixture.assertNoCanaries(after: "planted canary")
        }
        let snapshot = fixture.canaryRecords()
        fixture.assertNoNewCanaries(since: snapshot, after: "nothing new")
        try "args\nargs\n".write(to: planted, atomically: true, encoding: .utf8)
        XCTExpectFailure("a canary that grew must fail the difference check") {
            _ = fixture.assertNoNewCanaries(since: snapshot, after: "repeated payload")
        }
        try fixture.clearCanaries()
        XCTAssertEqual(fixture.canaries(), [])
    }
}
