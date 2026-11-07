import Foundation
import XCTest

@testable import Overgrove

/// Builders and invariant checks shared by the GRA tests (test-strategy.md §4.2).
///
/// Commits are named by small integers; `oid(n)` turns one into a fixed 40-digit SHA-1 so a test reads as a list of
/// `(oid, parents)` pairs.
enum GraphEngineTestSupport {
    static func oid(_ number: Int) -> ObjectID {
        guard let oid = ObjectID(String(format: "%040x", number)) else {
            preconditionFailure("test OID \(number) must be valid")
        }
        return oid
    }

    static func commit(_ number: Int, _ parents: Int...) -> CommitNode {
        commit(number, parents: parents)
    }

    static func commit(_ number: Int, parents: [Int]) -> CommitNode {
        CommitNode(
            oid: oid(number),
            parents: parents.map(oid),
            authorName: "t",
            authorEmail: "t@example.com",
            authorDate: Date(timeIntervalSince1970: 0),
            subject: "\(number)"
        )
    }

    static func segment(_ from: Int, _ to: Int, color: Int) -> GraphSegment {
        GraphSegment(from: from, to: to, colorIndex: color)
    }

    /// A deterministic history shaped like `scripts/make-bench-repo.sh` (benchmark-plan.md §2): a `main` line, two
    /// long-lived branches that are never merged, and short branches that live 5–44 commits, merge into `main` and
    /// start again. Commits are listed newest first, like `git log --date-order`.
    static func benchHistory(commitCount: Int, shortLanes: Int = 10) -> [CommitNode] {
        var generator = SplitMix64(seed: 0x6F76_6572_6772_6F76)
        var next = 1
        var commits: [CommitNode] = []
        commits.reserveCapacity(commitCount + shortLanes + 3)

        // Built oldest first, reversed at the end. Each tip is the newest commit of its branch.
        func add(_ parents: [Int]) -> Int {
            let number = next
            next += 1
            commits.append(commit(number, parents: parents))
            return number
        }
        var mainTip = add([])
        var longTips = [add([mainTip]), add([mainTip])]
        var shortTips = (0..<shortLanes).map { _ in add([mainTip]) }
        var shortRemaining = (0..<shortLanes).map { _ in Int(generator.next() % 40) + 5 }

        while commits.count < commitCount {
            let pick = Int(generator.next() % UInt64(3 + shortLanes))
            switch pick {
            case 0:
                mainTip = add([mainTip])
            case 1, 2:
                longTips[pick - 1] = add([longTips[pick - 1]])
            default:
                let lane = pick - 3
                if shortRemaining[lane] == 0 {
                    mainTip = add([mainTip, shortTips[lane]])
                    shortTips[lane] = add([mainTip])
                    shortRemaining[lane] = Int(generator.next() % 40) + 5
                } else {
                    shortTips[lane] = add([shortTips[lane]])
                    shortRemaining[lane] -= 1
                }
            }
        }
        return commits.reversed()
    }

    /// Checks properties every layout must have, whatever the history:
    /// - a segment either passes straight, arrives at the node, or leaves the previous row's node;
    /// - every segment starts where a line of the previous row continues downward;
    /// - a lane keeps its color from row to row.
    static func assertWellFormed(
        _ rows: [GraphRow],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for index in rows.indices {
            let row = rows[index]
            XCTAssertTrue((0..<8).contains(row.colorIndex), "row \(index) color", file: file, line: line)
            guard index > 0 else {
                XCTAssertTrue(row.incoming.isEmpty, "first row has nothing above it", file: file, line: line)
                continue
            }
            let above = rows[index - 1]
            // Lines that leave the row above downward: its node, and every lane that passes it without ending there.
            var continuing: [Int: Int] = [:]
            for segment in above.incoming where segment.to != above.column {
                continuing[segment.to] = segment.colorIndex
            }
            for segment in row.incoming {
                let shapeIsKnown =
                    segment.from == segment.to || segment.to == row.column || segment.from == above.column
                XCTAssertTrue(shapeIsKnown, "row \(index) segment \(segment)", file: file, line: line)
                if segment.from == above.column { continue }
                XCTAssertEqual(
                    continuing[segment.from],
                    segment.colorIndex,
                    "row \(index) segment \(segment) continues a lane of the row above",
                    file: file,
                    line: line
                )
            }
        }
    }
}

/// SplitMix64, so synthetic histories are identical on every run and machine (GRA-08).
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
