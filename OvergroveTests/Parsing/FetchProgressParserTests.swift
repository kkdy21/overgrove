import Foundation
import XCTest

@testable import Overgrove

/// PAR-FETCH-01…06 (parsing-spec.md §11.4).
final class FetchProgressParserTests: XCTestCase {
    /// Real `git fetch --progress` stderr (Apple Git 2.54.0, ssh transport, `LC_ALL=C`), trimmed to the first,
    /// middle, and last update of each phase. `remote:` lines carry git's trailing padding. Note the `remote: Total`
    /// line that interrupts "Receiving objects".
    private let realStderr = """
        remote: Enumerating objects: 304, done.        \nremote: Counting objects:   0% (1/304)        \rremote: \
        Counting objects:  50% (152/304)        \rremote: Counting objects: 100% (304/304)        \rremote: Counting \
        objects: 100% (304/304), done.        \nremote: Compressing objects:  50% (50/100)        \rremote: \
        Compressing objects: 100% (100/100)        \rremote: Compressing objects: 100% (100/100), done.        \n\
        Receiving objects:   0% (1/202)\rReceiving objects:  50% (101/202)\rremote: Total 202 (delta 102), reused 202 \
        (delta 102), pack-reused 0 (from 0)        \nReceiving objects: 100% (202/202)\rReceiving objects: 100% \
        (202/202), 304.96 KiB | 76.24 MiB/s, done.\nResolving deltas:   0% (0/102)\rResolving deltas:  50% (51/102)\r\
        Resolving deltas: 100% (102/102)\rResolving deltas: 100% (102/102), completed with 102 local objects.\nFrom \
        ssh://alpha/x\n   de36a64..4e24dcf  main       -> origin/main\n
        """

    private func progress(
        _ phase: FetchProgress.Phase,
        _ completed: Int,
        _ total: Int?,
        done: Bool = false
    ) -> FetchProgress {
        FetchProgress(phase: phase, completed: completed, total: total, isDone: done)
    }

    private func parseAll(_ text: String) -> [FetchProgress] {
        var parser = FetchProgressParser()
        return parser.consume(Data(text.utf8))
    }

    func testPARFETCH01_RealOutputYieldsEveryPhaseInOrder() {
        XCTAssertEqual(
            parseAll(realStderr),
            [
                progress(.enumerating, 304, nil, done: true),
                progress(.counting, 1, 304), progress(.counting, 152, 304), progress(.counting, 304, 304),
                progress(.counting, 304, 304, done: true),
                progress(.compressing, 50, 100), progress(.compressing, 100, 100),
                progress(.compressing, 100, 100, done: true),
                progress(.receiving, 1, 202), progress(.receiving, 101, 202), progress(.receiving, 202, 202),
                progress(.receiving, 202, 202, done: true),
                progress(.resolving, 0, 102), progress(.resolving, 51, 102), progress(.resolving, 102, 102),
                progress(.resolving, 102, 102, done: true),
            ]
        )
    }

    func testPARFETCH02_ChunkBoundariesDoNotMatter() {
        let whole = parseAll(realStderr)
        var parser = FetchProgressParser()
        var pieces: [FetchProgress] = []
        for byte in Data(realStderr.utf8) {
            pieces += parser.consume(Data([byte]))
        }
        XCTAssertEqual(pieces, whole)
    }

    func testPARFETCH03_OtherLinesAreIgnored() {
        let lines = [
            "From ssh://alpha/x\n", " * [new branch]      main       -> origin/main\n",
            "remote: Total 3 (delta 0), reused 0 (delta 0), pack-reused 0\n", "fatal: transport 'x' not allowed\n",
            "warning: redirecting to https://example.com/r.git/\n", "remote: Finding sources:  50% (1/2)\n",
        ]
        XCTAssertEqual(parseAll(lines.joined()), [])
    }

    func testPARFETCH04_MalformedNumbersAreIgnored() {
        // The server writes the `remote:` lines, so they are untrusted input.
        let hostile = [
            "Receiving objects: 150% (3/2)", "Receiving objects:  50% (3/2)", "Receiving objects:  50% (-1/2)",
            "Receiving objects:  50% (a/2)", "Receiving objects:  50% (1/2", "Receiving objects:  50 (1/2)",
            "Receiving objects: 50% (1/99999999999999999999999)", "Receiving objects:  50% (1/2)\u{1B}[K",
            "Receiving objects:  50% (1/2) trailing", "Receiving objects:", "Enumerating objects: x, done.",
            "Enumerating objects: -1", "Receiving objects:  ５０% (1/2)",
        ]
        for line in hostile {
            XCTAssertEqual(parseAll(line + "\n"), [], line)
        }
    }

    func testPARFETCH05_LongLinesAreDroppedAndParsingRecovers() {
        let flood = String(repeating: "x", count: FetchProgressParser.maximumLineLength * 4)
        var parser = FetchProgressParser()
        XCTAssertEqual(parser.consume(Data(flood.utf8)), [])
        XCTAssertEqual(parser.consume(Data("Receiving objects:  50% (1/2)\r".utf8)), [], "the rest of the long line")
        XCTAssertEqual(parser.consume(Data("Receiving objects: 100% (2/2)\r".utf8)), [progress(.receiving, 2, 2)])
    }

    func testPARFETCH06_RepeatedUpdatesAreReportedOnce() {
        // Throughput changes rewrite the line without changing the counts.
        let text = "Receiving objects:  50% (1/2), 1 KiB | 1 KiB/s\rReceiving objects:  50% (1/2), 2 KiB | 2 KiB/s\r"
        XCTAssertEqual(parseAll(text), [progress(.receiving, 1, 2)])
    }

    func testFraction() {
        XCTAssertEqual(progress(.receiving, 1, 4).fraction, 0.25)
        XCTAssertNil(progress(.enumerating, 10, nil).fraction)
        XCTAssertNil(progress(.resolving, 0, 0).fraction)
    }
}
