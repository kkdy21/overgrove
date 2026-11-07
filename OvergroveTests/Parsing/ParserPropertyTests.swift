import Foundation
import XCTest

@testable import Overgrove

/// Property-style parser tests, PAR-PROP-01…03 (parsing-spec.md §1.5, §1.6, §12; #58).
///
/// Inputs are real git output cut at every byte or mutated by a seeded generator, so every failure message names its
/// seed and iteration and reproduces exactly. The property is the same for every parser: it returns a result or throws
/// its own `ParseError` with an offset inside the input. It never crashes, hangs, throws another error, or returns a
/// record that the complete output does not have.
final class ParserPropertyTests: XCTestCase {
    private typealias Fixtures = AdversarialParserFixtures

    private static let seed: UInt64 = 0x0058_5EED
    private static let mutationsPerFixture = 300
    /// Generous: the whole suite takes well under a second locally. Exceeding it means a parser went super-linear.
    private static let timeBudget: TimeInterval = 10

    // MARK: - PAR-PROP-01

    /// Every cut of valid output: with `truncated` the parser drops the incomplete tail, flags `isPartial`, and keeps only
    /// records the complete output has, in order. Without `truncated` a cut inside a token is a format violation, and a
    /// cut at a record end parses as a prefix.
    func test_PAR_PROP_01_everyCutPointOfRealOutputIsAPrefixOrAParseError() throws {
        let start = Date()
        for subject in subjects where subject.honorsTruncation {
            for (fixtureIndex, fixture) in subject.fixtures.enumerated() {
                let full = try subject.parse(fixture, false)
                for cut in 0...fixture.count {
                    let input = Data(fixture.prefix(cut))
                    let context = "\(subject.label)[\(fixtureIndex)] cut \(cut)/\(fixture.count)"
                    if let parsed = check(subject, input, truncated: true, context) {
                        assertPrefix(parsed, of: full, context)
                    } else if cut > subject.truncatedNeeds.longestFailingCut(in: fixture) {
                        XCTFail("\(context): a cut of valid output must parse when truncated")
                    }
                    guard let parsed = check(subject, input, truncated: false, context) else { continue }
                    assertPrefix(parsed, of: full, context)
                    if input.last.map({ $0 != subject.terminator }) ?? false {
                        XCTFail("\(context): output without its final terminator was accepted when not truncated")
                    }
                }
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), Self.timeBudget)
    }

    // MARK: - PAR-PROP-02

    func test_PAR_PROP_02_randomMutationsParseOrThrowParseError() {
        let start = Date()
        for (subjectIndex, subject) in subjects.enumerated() {
            for (fixtureIndex, fixture) in subject.fixtures.enumerated() {
                let seed = Self.seed &+ UInt64(subjectIndex << 8 | fixtureIndex)
                var generator = SeededGenerator(seed: seed)
                for iteration in 0..<Self.mutationsPerFixture {
                    let input = Self.mutate(fixture, using: &generator)
                    let context = "\(subject.label)[\(fixtureIndex)] seed \(seed) iteration \(iteration)"
                    check(subject, input, truncated: false, context)
                    if subject.honorsTruncation { check(subject, input, truncated: true, context) }
                }
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), Self.timeBudget)
    }

    func test_PAR_PROP_02_issueRefExtractorReturnsOnlyNumbersFromTheText() {
        let samples = [
            "feat/58-adversarial-parser-inputs", "fix: a #12 and kkdy21/overgrove#34 (C#10, &#123;, issue#5)",
            "subject\n\nRefs: #58\r\nCloses #7\nFixes #0\n",
        ]
        for (sampleIndex, sample) in samples.enumerated() {
            let seed = Self.seed &+ UInt64(sampleIndex)
            var generator = SeededGenerator(seed: seed)
            for iteration in 0..<Self.mutationsPerFixture {
                let text = String(decoding: Self.mutate(Data(sample.utf8), using: &generator), as: UTF8.self)
                let lists = [
                    IssueRefExtractor.issueNumber(inBranch: text).map { [$0] } ?? [],
                    IssueRefExtractor.issueNumbers(inSubject: text, repository: "kkdy21/overgrove"),
                    IssueRefExtractor.issueNumbers(inTrailers: text),
                ]
                for numbers in lists {
                    let valid = numbers.allSatisfy { (1...9_999_999).contains($0) && text.contains(String($0)) }
                    if !valid || Set(numbers).count != numbers.count {
                        XCTFail("seed \(seed) iteration \(iteration): \(numbers) from \(text.debugDescription)")
                    }
                }
            }
        }
    }

    // MARK: - PAR-PROP-03

    /// `Data` slices keep their parent's indices. A parser that indexes from 0 instead of `startIndex` would read the
    /// wrong bytes or report a shifted offset, so a slice must give exactly the same result or error as a copy.
    func test_PAR_PROP_03_dataSlicesParseLikeCopies() {
        for (subjectIndex, subject) in subjects.enumerated() {
            for (fixtureIndex, fixture) in subject.fixtures.enumerated() {
                let seed = Self.seed &+ UInt64(subjectIndex << 8 | fixtureIndex)
                var generator = SeededGenerator(seed: seed)
                let inputs = [fixture] + (0..<20).map { _ in Self.mutate(fixture, using: &generator) }
                for (inputIndex, input) in inputs.enumerated() {
                    let slice = (Data([0x00, 0x41, 0x0A]) + input).dropFirst(3)
                    for truncated in subject.honorsTruncation ? [false, true] : [false] {
                        XCTAssertEqual(
                            outcome(subject, slice, truncated: truncated),
                            outcome(subject, input, truncated: truncated),
                            "\(subject.label)[\(fixtureIndex)] seed \(seed) input \(inputIndex) truncated \(truncated)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Checks

    /// Runs one parse and checks the universal property. Returns `nil` when the parser threw its `ParseError`.
    @discardableResult
    private func check(
        _ subject: Subject,
        _ input: Data,
        truncated: Bool,
        _ context: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Parsed? {
        do {
            let parsed = try subject.parse(input, truncated)
            if let isPartial = parsed.isPartial, isPartial != truncated {
                XCTFail("\(context()): isPartial \(isPartial), truncated \(truncated)", file: file, line: line)
            }
            for path in parsed.paths where !Self.isWellFormed(path) {
                XCTFail("\(context()): malformed path \(path.raw as NSData)", file: file, line: line)
            }
            return parsed
        } catch let error as ParseError {
            if error.parser != subject.parser {
                XCTFail("\(context()): error from \(error.parser)", file: file, line: line)
            }
            if subject.hasByteOffsets, !(0...input.count).contains(error.offset) {
                XCTFail("\(context()): offset \(error.offset) outside 0...\(input.count)", file: file, line: line)
            }
            return nil
        } catch {
            XCTFail("\(context()): \(error) is not a ParseError", file: file, line: line)
            return nil
        }
    }

    /// Tokens are split at NUL, so a path never contains one; a representable path goes back to git byte for byte.
    private static func isWellFormed(_ path: GitPath) -> Bool {
        guard !path.raw.isEmpty, !path.raw.contains(0) else { return false }
        return path.argument.map { Data($0.utf8) == path.raw } ?? !path.isRepresentable
    }

    private func assertPrefix(_ parsed: Parsed, of full: Parsed, _ context: String) {
        guard parsed.lists.count == full.lists.count else { return XCTFail("\(context): list count differs") }
        for (part, whole) in zip(parsed.lists, full.lists) where !whole.starts(with: part) {
            XCTFail("\(context): \(part.count) records are not a prefix of the complete output's \(whole.count)")
        }
    }

    private enum Outcome: Equatable {
        case parsed(Parsed)
        case failed(ParseError)
        case unexpected(String)
    }

    private func outcome(_ subject: Subject, _ input: Data, truncated: Bool) -> Outcome {
        do {
            return .parsed(try subject.parse(input, truncated))
        } catch let error as ParseError {
            return .failed(error)
        } catch {
            return .unexpected(String(describing: error))
        }
    }

    // MARK: - Mutation

    private static let interestingBytes =
        Array("\u{0}\n\t :#-.0129af{}@\"\\/".utf8) + [0x7F, 0x80, 0xC3, 0xE2, 0xFE, 0xFF]

    /// One to four edits: replace, delete, or insert a byte (often a separator or a UTF-8 lead byte), or duplicate a
    /// short run elsewhere so that whole fields shift.
    private static func mutate(_ data: Data, using generator: inout SeededGenerator) -> Data {
        var bytes = [UInt8](data)
        for _ in 0..<Int.random(in: 1...4, using: &generator) {
            let index = Int.random(in: 0...bytes.count, using: &generator)
            let byte =
                Bool.random(using: &generator)
                ? interestingBytes[Int.random(in: interestingBytes.indices, using: &generator)]
                : UInt8.random(in: 0...255, using: &generator)
            switch Int.random(in: 0..<4, using: &generator) {
            case 0 where index < bytes.count:
                bytes[index] = byte
            case 1 where index < bytes.count:
                bytes.remove(at: index)
            case 2 where index < bytes.count:
                let run = Array(bytes[index..<min(bytes.count, index + Int.random(in: 1...16, using: &generator))])
                let target = Int.random(in: 0...bytes.count, using: &generator)
                bytes.insert(contentsOf: run, at: target)
            default:
                bytes.insert(byte, at: index)
            }
        }
        return Data(bytes)
    }

    // MARK: - Subjects

    /// What a parser returned, reduced to comparable parts.
    private struct Parsed: Equatable {
        /// Record lists in output order. Cutting the output may only shorten them.
        var lists: [[AnyHashable]] = []
        /// Everything else the parser returned.
        var rest: AnyHashable?
        var isPartial: Bool?
        var paths: [GitPath] = []
    }

    private struct Subject {
        /// `ParseError.parser`.
        let parser: String
        let label: String
        let fixtures: [Data]
        /// JSON parsers report a record index instead of a byte offset.
        var hasByteOffsets = true
        /// Records end with `terminator` and the parser honors `truncated` (§1.5).
        var honorsTruncation = true
        /// NUL for `-z` output, LF for `for-each-ref`.
        var terminator: UInt8 = 0
        /// What a truncated cut of a valid fixture must keep to parse, e.g. required headers.
        var truncatedNeeds: Requirement = .nothing
        let parse: (_ data: Data, _ truncated: Bool) throws -> Parsed
    }

    private enum Requirement {
        case nothing
        /// The complete token starting with this prefix, plus at least one more byte (the last token is dropped).
        case tokenStarting(String)
        /// This many complete tokens, plus at least one more byte.
        case tokens(Int)

        /// The longest cut that may still fail.
        func longestFailingCut(in fixture: Data) -> Int {
            switch self {
            case .nothing: -1
            case .tokenStarting(let prefix): ParserPropertyTests.end(ofTokenStarting: prefix, in: fixture)
            case .tokens(let count): ParserPropertyTests.offset(afterNUL: count, in: fixture)
            }
        }
    }

    private static func erase<T: Hashable>(_ values: [T]) -> [AnyHashable] { values.map { AnyHashable($0) } }

    /// The byte after the NUL that ends the first token starting with `prefix`.
    private static func end(ofTokenStarting prefix: String, in data: Data) -> Int {
        guard let start = data.firstRange(of: Data(prefix.utf8))?.lowerBound,
            let nul = data[start...].firstIndex(of: 0)
        else { return data.count }
        return nul + 1
    }

    /// The byte after the `count`-th NUL.
    private static func offset(afterNUL count: Int, in data: Data) -> Int {
        var seen = 0
        for (index, byte) in data.enumerated() where byte == 0 {
            seen += 1
            if seen == count { return index + 1 }
        }
        return data.count
    }

    /// Split into groups so the type checker handles each array literal quickly.
    private var subjects: [Subject] { worktreeStatusLogSubjects + configFileRefSubjects + lineAndJSONSubjects }

    private var worktreeStatusLogSubjects: [Subject] {
        [
            Subject(parser: "WorktreeParser", label: "worktree", fixtures: [Fixtures.worktree]) { data, truncated in
                let listing = try WorktreeParser.parse(data, truncated: truncated)
                let worktrees = listing.worktrees
                return Parsed(
                    lists: [Self.erase(worktrees)], isPartial: listing.isPartial, paths: worktrees.map(\.path))
            },
            Subject(
                parser: "StatusParser",
                label: "status",
                fixtures: [Fixtures.status],
                // Status needs both branch headers; the last complete token is dropped too (§1.5).
                truncatedNeeds: .tokenStarting("# branch.head")
            ) { data, truncated in
                let state = try StatusParser.parse(data, truncated: truncated)
                let changes = state.staged + state.unstaged + state.untracked + state.conflicted
                let headers: [AnyHashable] = [
                    state.headCommit, state.head, state.upstream, state.stashCount, state.skippedRecords,
                ]
                return Parsed(
                    lists: [state.staged, state.unstaged, state.untracked, state.conflicted].map(Self.erase),
                    rest: headers,
                    isPartial: state.isPartial,
                    paths: changes.map(\.path) + changes.compactMap(\.originalPath)
                )
            },
            Subject(parser: "StashParser", label: "stash", fixtures: [Fixtures.stash]) { data, truncated in
                let listing = try StashParser.parse(data, truncated: truncated)
                return Parsed(lists: [Self.erase(listing.stashes)], isPartial: listing.isPartial)
            },
            Subject(
                parser: "LogParser",
                label: "log graph",
                fixtures: [
                    LogParserFixtures.sha1Graph, LogParserFixtures.sha256Graph, LogParserFixtures.nulMessageGraph,
                    LogParserFixtures.coAuthorGraph,
                ]
            ) { data, truncated in
                let page = try LogParser.parseGraph(data, truncated: truncated)
                return Parsed(lists: [Self.erase(page.commits)], isPartial: page.isPartial)
            },
            Subject(
                parser: "LogParser",
                label: "log detail",
                fixtures: [LogParserFixtures.sha1Detail, LogParserFixtures.nulMessageDetail],
                // The eight fields before the message must be complete.
                truncatedNeeds: .tokens(8)
            ) { data, truncated in
                let meta = try LogParser.parseCommitMeta(data, truncated: truncated)
                let fields: [AnyHashable] = [
                    meta.oid, meta.parents, meta.authorName, meta.authorEmail, meta.authorDate, meta.committerName,
                    meta.committerEmail, meta.committerDate, meta.message,
                ]
                return Parsed(rest: fields, isPartial: meta.isPartial)
            },
        ]
    }

    private var configFileRefSubjects: [Subject] {
        [
            Subject(parser: "ConfigParser", label: "config", fixtures: [Fixtures.config]) { data, truncated in
                let listing = try ConfigParser.parse(data, truncated: truncated)
                return Parsed(lists: [Self.erase(listing.entries)], isPartial: listing.isPartial)
            },
            Subject(parser: "NumstatParser", label: "commit files", fixtures: [Fixtures.numstat]) { data, truncated in
                let result = try NumstatParser.parseCommitFiles(data, truncated: truncated)
                let files = result.files
                return Parsed(
                    lists: [Self.erase(files)],
                    isPartial: result.isPartial,
                    paths: files.map(\.path) + files.compactMap(\.originalPath)
                )
            },
            Subject(parser: "NumstatParser", label: "stash files", fixtures: [Fixtures.stashShow]) { data, truncated in
                let result = try NumstatParser.parseStashFiles(data, truncated: truncated)
                let files = result.files
                return Parsed(
                    lists: [Self.erase(files)],
                    isPartial: result.isPartial,
                    paths: files.map(\.path) + files.compactMap(\.originalPath)
                )
            },
            Subject(parser: "RefParser", label: "refs", fixtures: [Fixtures.refs], terminator: 0x0A) {
                data, truncated in
                let listing = try RefParser.parse(data, truncated: truncated)
                return Parsed(
                    lists: [Self.erase(listing.branches), Self.erase(listing.tags)],
                    rest: listing.skippedRecords,
                    isPartial: listing.isPartial
                )
            },
        ]
    }

    private var lineAndJSONSubjects: [Subject] {
        [
            Subject(
                parser: "RevListParser",
                label: "rev-list",
                fixtures: [Fixtures.revList],
                honorsTruncation: false
            ) { data, _ in
                let counts = try RevListParser.parse(data)
                return Parsed(rest: [counts.behind, counts.ahead])
            },
            Subject(
                parser: "VersionParser",
                label: "version",
                fixtures: [Data("git version 2.50.1 (Apple Git-155)\n".utf8), Data("git version 2.47.0.rc1".utf8)],
                honorsTruncation: false
            ) { data, _ in Parsed(rest: try VersionParser.parse(data)) },
            Subject(
                parser: "GHAuthParser",
                label: "gh auth",
                fixtures: [
                    Data(
                        #"{"hosts":{"github.com":[{"active":true,"gitProtocol":"https","host":"github.com","login":"octo-cat","#
                            .utf8
                    ) + Data(#""scopes":"repo","state":"success","tokenSource":"keyring"}]}}"#.utf8)
                ],
                hasByteOffsets: false,
                honorsTruncation: false
            ) { data, _ in Parsed(rest: try GHAuthParser.parse(data)) },
            Subject(
                parser: "IssueParser",
                label: "gh issues",
                fixtures: [
                    Data(
                        (#"[{"number":12,"title":"feat: x","state":"OPEN","labels":[{"name":"a","color":"1f6feb"}],"#
                            + #""assignees":[{"login":"octo-cat"}],"updatedAt":"2026-11-05T06:11:06Z","#
                            + #""url":"https://github.com/kkdy21/overgrove/issues/12"}]"#).utf8
                    )
                ],
                hasByteOffsets: false,
                honorsTruncation: false
            ) { data, _ in Parsed(lists: [Self.erase(try IssueParser.parse(data))]) },
        ]
    }
}

/// SplitMix64: tiny, fast, and identical on every run for the same seed.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
