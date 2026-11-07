import Foundation
import XCTest

@testable import Overgrove

/// One canary of the `--malicious` fixture: the file a harmless payload writes into `canary/` when git runs it
/// (docs/testing/fixtures.md §8.1). The file name tells which repository-configured program ran.
struct Canary: Sendable, Hashable {
    /// The canary file name, e.g. `T1-fsmonitor`.
    let id: String
    /// Threat ID from docs/design/security-review.md, e.g. `T1`.
    let threat: String
    /// The configuration that planted the payload.
    let mechanism: String

    /// Every canary the fixture can write. `CanaryHarnessTests` checks this list against the generated fixture, so a
    /// payload added to `scripts/make-fixture-repo.sh` without a row here (and in fixtures.md §8.1) fails a test.
    static let all: [Canary] =
        [Canary(id: "T1-fsmonitor", threat: "T1", mechanism: "core.fsmonitor")]
        + hookNames.map { Canary(id: "T2-hook-\($0)", threat: "T2", mechanism: "core.hooksPath → \($0) hook") }
        + [
            Canary(id: "T3-textconv", threat: "T3", mechanism: "diff.<driver>.textconv via attributes"),
            Canary(id: "T3-external-diff", threat: "T3", mechanism: "diff.external (from include.path)"),
            Canary(id: "T4-filter-clean", threat: "T4", mechanism: "filter.<driver>.clean via attributes"),
            Canary(id: "T4-filter-smudge", threat: "T4", mechanism: "filter.<driver>.smudge via attributes"),
            Canary(id: "T4-filter-process", threat: "T4", mechanism: "filter.<driver>.process via attributes"),
            Canary(id: "T5-sshCommand", threat: "T5", mechanism: "core.sshCommand (ssh remote or insteadOf)"),
            Canary(id: "T5-gitProxy", threat: "T5", mechanism: "core.gitProxy (git:// remote)"),
            Canary(id: "T5-uploadpack", threat: "T5", mechanism: "remote.<name>.uploadpack"),
            Canary(id: "T5-alternateRefsCommand", threat: "T5", mechanism: "core.alternateRefsCommand + alternates"),
            Canary(id: "T5-ext-transport", threat: "T5", mechanism: "ext:: remote transport"),
            Canary(id: "T6-credential-helper", threat: "T6", mechanism: "credential.helper"),
            Canary(id: "T6-askpass", threat: "T6/T12", mechanism: "core.askPass"),
            Canary(id: "T7-gpg-program", threat: "T7", mechanism: "gpg.program (+ log.showSignature)"),
        ]

    /// Hooks planted under `core.hooksPath` (fixtures.md §8.1).
    static let hookNames = [
        "post-index-change", "reference-transaction", "post-checkout", "post-merge", "pre-auto-gc", "post-rewrite",
        "pre-commit",
    ]

    /// Human-readable explanation of a canary file name for failure messages.
    static func explain(_ id: String) -> String {
        guard let canary = all.first(where: { $0.id == id }) else {
            return "\(id): unknown canary (add it to Canary.all and docs/testing/fixtures.md §8.1)"
        }
        return "\(canary.id): \(canary.threat), \(canary.mechanism)"
    }
}

extension FixtureRepo {
    /// Canary files written so far, with what each payload recorded (one line per run: the arguments it got).
    func canaryRecords() -> [String: String] {
        var records: [String: String] = [:]
        for id in canaries() {
            let file = canary.appendingPathComponent(id)
            records[id] = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        }
        return records
    }

    /// Empties `canary/` so the next step is judged on its own.
    func clearCanaries() throws {
        for id in canaries() {
            try FileManager.default.removeItem(at: canary.appendingPathComponent(id))
        }
    }

    /// Fails when any payload ran, naming the action, each threat, and what the payload received.
    func assertNoCanaries(after action: String, file: StaticString = #filePath, line: UInt = #line) {
        let records = canaryRecords()
        guard !records.isEmpty else { return }
        XCTFail(Self.canaryFailureMessage(action: action, records: records), file: file, line: line)
    }

    /// Exposed for testing the message itself.
    static func canaryFailureMessage(action: String, records: [String: String]) -> String {
        let lines = records.keys.sorted().map { id in
            let record = records[id, default: ""]
            let runs = max(record.split(separator: "\n", omittingEmptySubsequences: false).count - 1, 1)
            return "  - \(Canary.explain(id)) — ran \(runs)×, args: \(record.debugDescription)"
        }
        return "\(action) ran \(records.count) repository-configured program(s):\n" + lines.joined(separator: "\n")
    }
}
