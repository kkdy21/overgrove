import Foundation
import XCTest

/// How the PERF tests run (benchmark-plan.md §3, §7, #90).
///
/// Every PERF test is opt-in, because CI runners are too noisy to gate on (test-strategy.md, "성능 테스트는 필수 검사에
/// 넣지 않는다"). The switches are environment variables; with xcodebuild, prefix each with `TEST_RUNNER_`:
///
/// | Variable | Effect |
/// |---|---|
/// | `OVERGROVE_BENCH_REPO=<dir>` | A `scripts/make-bench-repo.sh` output directory: runs PERF-01, -02, -03, -11, -12 |
/// | `OVERGROVE_PERF=1` | Runs the synthetic PERF tests (PERF-05, PERF-09) |
/// | `OVERGROVE_PERF_REPORT_ONLY=1` | Budgets are reported, not enforced (CI runners) |
/// | `OVERGROVE_PERF_REPORT_DIR=<dir>` | Each test also writes its result table to `<dir>/PERF-nn.md` |
enum PerfRun {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// The bench repository's main worktree (`<dir>/repo`), or a skip.
    static func benchRepository() throws -> URL {
        guard let bench = environment["OVERGROVE_BENCH_REPO"], !bench.isEmpty else {
            throw XCTSkip("set OVERGROVE_BENCH_REPO to a make-bench-repo.sh output directory (benchmark-plan.md §7)")
        }
        return URL(fileURLWithPath: bench).appendingPathComponent("repo", isDirectory: true)
    }

    /// Skips unless synthetic PERF tests are on. `OVERGROVE_BENCH_DIFF=1` (#232) still turns on PERF-09.
    static func requireSynthetic(legacy: String? = nil) throws {
        let isOn = environment["OVERGROVE_PERF"] == "1" || legacy.map { environment[$0] == "1" } ?? false
        guard isOn else { throw XCTSkip("set OVERGROVE_PERF=1 to measure (benchmark-plan.md §7)") }
    }

    /// CI runners report budgets without failing (benchmark-plan.md §5).
    static var isReportOnly: Bool { environment["OVERGROVE_PERF_REPORT_ONLY"] == "1" }

    /// A HOME that holds no user configuration, so the user's `~/.gitconfig` does not change what is measured.
    static let isolatedParentEnvironment = ["HOME": FileManager.default.temporaryDirectory.path]

    static var reportDirectory: URL? {
        environment["OVERGROVE_PERF_REPORT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }
}

/// Timed samples with a warm-up dropped (performance-budget.md §1: nearest-rank p95).
struct PerfSamples {
    let samples: [Duration]

    init(_ samples: [Duration]) {
        self.samples = samples.sorted()
    }

    var p50: Duration { samples[samples.count / 2] }
    /// Nearest rank: the 19th of 20.
    var p95: Duration { samples[max(Int((Double(samples.count) * 0.95).rounded(.up)) - 1, 0)] }
    var maximum: Duration { samples[samples.count - 1] }

    /// Runs `body` `runs` times and keeps all but the first `warmUp` timings.
    static func measure(runs: Int, warmUp: Int = 1, _ body: () async throws -> Void) async rethrows -> PerfSamples {
        var kept: [Duration] = []
        for run in 0..<runs {
            let started = ContinuousClock.now
            try await body()
            if run >= warmUp { kept.append(ContinuousClock.now - started) }
        }
        return PerfSamples(kept)
    }

    static func measure(runs: Int, warmUp: Int = 1, _ body: () throws -> Void) rethrows -> PerfSamples {
        var kept: [Duration] = []
        for run in 0..<runs {
            let started = ContinuousClock.now
            try body()
            if run >= warmUp { kept.append(ContinuousClock.now - started) }
        }
        return PerfSamples(kept)
    }
}

/// One PERF test's result table: printed as `PERF-nn RESULT`, optionally written to the report directory, and
/// checked against its budgets.
struct PerfReport {
    let id: String
    let title: String
    private(set) var rows: [(measure: String, value: String, budget: String, verdict: String)] = []
    private(set) var notes: [String] = []
    private var overBudget: [String] = []

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    mutating func note(_ text: String) {
        notes.append(text)
    }

    /// Records `samples` and checks `p95` (or `max` when `usesMaximum`) against `budget`.
    mutating func record(
        _ measure: String, _ samples: PerfSamples, budget: Duration? = nil, budgetLabel: String? = nil,
        usesMaximum: Bool = false
    ) {
        let value =
            "p50 \(Self.format(samples.p50)), p95 \(Self.format(samples.p95)), max \(Self.format(samples.maximum))"
        let checked = usesMaximum ? samples.maximum : samples.p95
        record(measure, value: value, checked: checked, budget: budget, budgetLabel: budgetLabel)
    }

    mutating func record(
        _ measure: String, value: String, checked: Duration? = nil, budget: Duration? = nil, budgetLabel: String? = nil
    ) {
        var verdict = "—"
        if let budget, let checked {
            verdict = checked < budget ? "within" : "**over**"
            if checked >= budget { overBudget.append("\(measure): \(Self.format(checked)) ≥ \(Self.format(budget))") }
        }
        rows.append((measure, value, budgetLabel ?? budget.map(Self.format) ?? "—", verdict))
    }

    var markdown: String {
        var lines = ["### \(id) \(title)", "", "| Measure | Value | Budget | Verdict |", "|---|---|---|---|"]
        lines += rows.map { "| \($0.measure) | \($0.value) | \($0.budget) | \($0.verdict) |" }
        if !notes.isEmpty { lines += [""] + notes.map { "- \($0)" } }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Prints, writes, and fails on an over-budget value unless budgets are report-only.
    func finish(file: StaticString = #filePath, line: UInt = #line) {
        print("\(id) RESULT\n" + markdown)
        if let directory = PerfRun.reportDirectory {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(markdown.utf8).write(to: directory.appendingPathComponent("\(id).md"))
            } catch {
                XCTFail("could not write the \(id) report: \(error)", file: file, line: line)
            }
        }
        guard !overBudget.isEmpty, !PerfRun.isReportOnly else { return }
        XCTFail("\(id) over budget: " + overBudget.joined(separator: "; "), file: file, line: line)
    }

    static func format(_ duration: Duration) -> String {
        let microseconds = Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
        if microseconds < 1000 { return String(format: "%.0f µs", microseconds) }
        return String(format: microseconds < 100_000 ? "%.1f ms" : "%.0f ms", microseconds / 1000)
    }
}
