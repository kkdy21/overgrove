import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import Overgrove

/// PERF-09 (PB-9): S-10 diff rendering cost (#232): parsing a patch, building rows, and the first rendered screen,
/// for diffs from typical to the 10 MB output cap (ADR-0008). Results: docs/performance/results/2026-11-07-s10-diff-viewer.md.
///
/// Skipped unless `OVERGROVE_PERF=1` or `OVERGROVE_BENCH_DIFF=1` (`PerfRun`). Up to the 10,000-line gate, parsing and
/// rows (both off the main thread) are held to PB-9's 200 ms, and the first frame to 16 ms at every size.
@MainActor
final class DiffViewerBenchmarkTests: XCTestCase {
    private static let runs = 11  // the first is a warm-up and is dropped (performance-budget.md §1)

    /// A patch of `lines` changed lines, 60 characters each, in hunks of 20. With `wordsDiffer`, each added line differs
    /// from its removed line by one word, so every pair goes through the word-level comparison (#387).
    private static func patch(lines: Int, wordsDiffer: Bool = false) -> Data {
        var text = "diff --git a/big.swift b/big.swift\n--- a/big.swift\n+++ b/big.swift\n"
        text.reserveCapacity(lines * 64)
        let body = String(repeating: "x", count: 58)
        var line = 0
        while line < lines {
            let count = min(20, lines - line)
            let half = count / 2
            text += "@@ -\(line + 1),\(half) +\(line + 1),\(count - half) @@ func f\(line)()\n"
            for index in 0..<count {
                let removed = index < half
                let content =
                    wordsDiffer
                    ? "let alpha = \(removed ? "beta" : "bravo").gamma(delta, epsilon) + zeta * eta // theta" : body
                text += (removed ? "-" : "+") + "\t" + content + "\n"
            }
            line += count
        }
        return Data(text.utf8)
    }

    func test_PERF_09_diffRendering() throws {
        try PerfRun.requireSynthetic(legacy: "OVERGROVE_BENCH_DIFF")
        var report = PerfReport(id: "PERF-09", title: "Diff viewer rendering (PB-9)")
        report.note("git excluded; parsing and rows run off the main thread")
        // 500 lines (typical), the 10,000-line gate, and about 10 MB (the output cap).
        let cases = [
            (500, false), (DiffDocument.largeLineThreshold, false), (DiffDocument.largeLineThreshold, true),
            (160_000, false),
        ]
        for (lines, wordsDiffer) in cases {
            let data = Self.patch(lines: lines, wordsDiffer: wordsDiffer)
            var parse: [Duration] = []
            var opened: [Duration] = []
            var splitRows: [Duration] = []
            var screen: [Duration] = []
            for run in 0..<Self.runs {
                var started = ContinuousClock.now
                let listing = try PatchParser.parse(data)
                let parsed = ContinuousClock.now - started

                let document = DiffDocument(
                    listing: listing, path: GitPath("big.swift"), source: .init(label: "Unstaged", kindLetter: "M"))
                started = ContinuousClock.now
                let built = document.unifiedRows(marked: true)
                let rowTime = ContinuousClock.now - started
                XCTAssertEqual(built.count, lines + (lines + 19) / 20)
                started = ContinuousClock.now
                _ = document.splitRows(marked: true)
                let splitTime = ContinuousClock.now - started

                // The first frame on the main thread: rows are built off it, so this stays small at any size.
                started = ContinuousClock.now
                let host = NSHostingView(
                    rootView: DiffViewerView(
                        title: "big.swift", sourceLabel: "Unstaged · M", state: .loaded(document), onBack: {}
                    )
                    .frame(width: 1000, height: 800)
                    // Unified, whatever view mode the app saved on this Mac (#601).
                    .defaultAppStorage(UserDefaults(suiteName: "overgrove-diff-benchmark") ?? .standard))
                host.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
                host.layoutSubtreeIfNeeded()
                let firstScreen = ContinuousClock.now - started

                if run > 0 {
                    parse.append(parsed)
                    opened.append(parsed + rowTime)
                    splitRows.append(splitTime)
                    screen.append(firstScreen)
                }
            }
            let size = "\(lines) lines, \(data.count / 1024) KiB" + (wordsDiffer ? ", words differ" : "")
            let isGated = lines <= DiffDocument.largeLineThreshold
            report.record("\(size): parse", PerfSamples(parse))
            report.record(
                "\(size): parse + unified rows", PerfSamples(opened), budget: isGated ? .milliseconds(200) : nil,
                budgetLabel: isGated ? "200 ms (PB-9)" : "— (large-diff gate shown first)")
            report.record("\(size): split rows", PerfSamples(splitRows))
            report.record(
                "\(size): first frame", PerfSamples(screen), budget: .milliseconds(16), budgetLabel: "16 ms (PB-9)")
        }
        report.finish()
    }
}
