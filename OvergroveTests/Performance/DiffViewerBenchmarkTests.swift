import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import Overgrove

/// S-10 diff rendering cost (#232): parsing a patch, building rows, and the first rendered screen, for diffs from
/// typical to the 10 MB output cap (ADR-0008). Results: docs/performance/results/2026-11-07-s10-diff-viewer.md.
///
/// Skipped unless `OVERGROVE_BENCH_DIFF=1` (xcodebuild: `TEST_RUNNER_OVERGROVE_BENCH_DIFF=1`). Not part of CI.
@MainActor
final class DiffViewerBenchmarkTests: XCTestCase {
    private static let runs = 11  // the first is a warm-up and is dropped (performance-budget.md §1)

    /// A patch of `lines` changed lines, 60 characters each, in hunks of 20.
    private static func patch(lines: Int) -> Data {
        var text = "diff --git a/big.swift b/big.swift\n--- a/big.swift\n+++ b/big.swift\n"
        text.reserveCapacity(lines * 64)
        let body = String(repeating: "x", count: 58)
        var line = 0
        while line < lines {
            let count = min(20, lines - line)
            let half = count / 2
            text += "@@ -\(line + 1),\(half) +\(line + 1),\(count - half) @@ func f\(line)()\n"
            for index in 0..<count { text += (index < half ? "-" : "+") + "\t" + body + "\n" }
            line += count
        }
        return Data(text.utf8)
    }

    private func percentiles(_ samples: [Duration]) -> String {
        let sorted = samples.sorted()
        let ms = { (d: Duration) in Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
        return String(
            format: "p50 %.1f ms, p95 %.1f ms", ms(sorted[sorted.count / 2]), ms(sorted[sorted.count * 95 / 100]))
    }

    func testDiffRenderingCost() throws {
        guard ProcessInfo.processInfo.environment["OVERGROVE_BENCH_DIFF"] == "1" else {
            throw XCTSkip("set OVERGROVE_BENCH_DIFF=1 to measure")
        }
        var report: [String] = []
        // 500 lines (typical), the 10,000-line gate, and about 10 MB (the output cap).
        for lines in [500, DiffDocument.largeLineThreshold, 160_000] {
            let data = Self.patch(lines: lines)
            var parse: [Duration] = []
            var rows: [Duration] = []
            var splitRows: [Duration] = []
            var screen: [Duration] = []
            for run in 0..<Self.runs {
                var started = ContinuousClock.now
                let listing = try PatchParser.parse(data)
                let parsed = ContinuousClock.now - started

                let document = DiffDocument(
                    listing: listing, path: GitPath("big.swift"), source: .init(label: "Unstaged", kindLetter: "M"))
                started = ContinuousClock.now
                let built = document.unifiedRows()
                let rowTime = ContinuousClock.now - started
                XCTAssertEqual(built.count, lines + (lines + 19) / 20)
                started = ContinuousClock.now
                _ = document.splitRows()
                let splitTime = ContinuousClock.now - started

                // The first frame on the main thread: rows are built off it, so this stays small at any size.
                started = ContinuousClock.now
                let host = NSHostingView(
                    rootView: DiffViewerView(
                        title: "big.swift", sourceLabel: "Unstaged · M", state: .loaded(document), onBack: {}
                    )
                    .frame(width: 1000, height: 800))
                host.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
                host.layoutSubtreeIfNeeded()
                let firstScreen = ContinuousClock.now - started

                if run > 0 {
                    parse.append(parsed)
                    rows.append(rowTime)
                    splitRows.append(splitTime)
                    screen.append(firstScreen)
                }
            }
            report.append(
                "\(lines) lines, \(data.count / 1024) KiB: parse \(percentiles(parse)); unified rows \(percentiles(rows)); split rows \(percentiles(splitRows)); first frame \(percentiles(screen))"
                    + (lines > DiffDocument.largeLineThreshold ? " (large-diff gate shown)" : ""))
        }
        print("DIFF-BENCH\n" + report.joined(separator: "\n"))
    }
}
