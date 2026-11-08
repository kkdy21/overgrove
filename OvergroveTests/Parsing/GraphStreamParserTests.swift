import Foundation
import XCTest

@testable import Overgrove

/// PAR-LOG-13 (#254): the streamed graph parsed chunk by chunk gives exactly what `parseGraph` gives for the whole
/// output, wherever the chunks are cut.
final class GraphStreamParserTests: XCTestCase {
    private typealias Fixtures = LogParserFixtures

    private func streamed(_ data: Data, chunk size: Int) throws -> [CommitNode] {
        var parser = GraphStreamParser()
        var commits: [CommitNode] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = min(start + size, data.endIndex)
            commits += try parser.feed(Data(data[start..<end]))
            start = end
        }
        try parser.finish(truncated: false)
        return commits
    }

    func testPARLOG13_AnyChunkingMatchesTheWholeOutput() throws {
        for fixture in [Fixtures.sha1Graph, Fixtures.sha256Graph, Fixtures.coAuthorGraph, Fixtures.nulMessageGraph] {
            let whole = try LogParser.parseGraph(fixture).commits
            XCTAssertFalse(whole.isEmpty)
            for size in [1, 2, 3, 7, 40, 41, 97, 1024, fixture.count] {
                XCTAssertEqual(try streamed(fixture, chunk: size), whole, "chunk \(size)")
            }
        }
    }

    func testPARLOG13_ACompleteRecordIsReturnedAsSoonAsItsLastNULArrives() throws {
        let data = Fixtures.sha1Graph
        let first = try XCTUnwrap(LogParser.parseGraph(data).commits.first)
        let end = try XCTUnwrap(Self.recordEnds(data).first)
        var parser = GraphStreamParser()
        XCTAssertEqual(try parser.feed(Data(data[..<(end - 1)])), [], "one NUL short of a record")
        XCTAssertEqual(try parser.feed(Data(data[(end - 1)..<end])), [first])
    }

    func testPARLOG13_AnEndInsideARecordFailsUnlessTruncated() throws {
        let data = Fixtures.sha1Graph
        let cut = Data(data[..<(data.count - 5)])
        var complete = GraphStreamParser()
        _ = try complete.feed(cut)
        XCTAssertThrowsError(try complete.finish(truncated: false)) { error in
            XCTAssertEqual((error as? ParseError)?.reason, "incomplete record")
            XCTAssertEqual((error as? ParseError)?.offset, cut.count)
        }
        var truncated = GraphStreamParser()
        let commits = try truncated.feed(cut)
        XCTAssertNoThrow(try truncated.finish(truncated: true))
        XCTAssertEqual(commits, Array(try LogParser.parseGraph(data).commits.dropLast()), "the cut record is dropped")
    }

    func testPARLOG13_ABadRecordFailsWithItsOffsetInTheWholeStream() throws {
        let good = Fixtures.sha1Graph
        let bad = Data("not-an-oid\0\0a\0a@example.com\01\0s\0\0".utf8)
        var parser = GraphStreamParser()
        _ = try parser.feed(good)
        XCTAssertThrowsError(try parser.feed(bad)) { error in
            let offset = (error as? ParseError)?.offset ?? -1
            XCTAssertGreaterThanOrEqual(offset, good.count, "offset counts the bytes already consumed")
        }
    }

    /// Byte offsets just after each record (every seventh NUL).
    private static func recordEnds(_ data: Data) -> [Int] {
        var ends: [Int] = []
        var nuls = 0
        for (index, byte) in data.enumerated() where byte == 0 {
            nuls += 1
            if nuls % 7 == 0 { ends.append(index + 1) }
        }
        return ends
    }
}
