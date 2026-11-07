import Foundation
import XCTest

@testable import Overgrove

/// Adversarial inputs across parsers for the boundary cases in parsing-spec.md §12 (#58).
///
/// Each parser's own test file covers its format. This file feeds the same hostile names and broken structure to every
/// parser that can receive them, mostly from real git output (`AdversarialParserFixtures`). Test names carry the PAR ID
/// of the §12 row they extend. Exhaustive cut points and random mutations are in `ParserPropertyTests`.
final class AdversarialParserTests: XCTestCase {
    private typealias Fixtures = AdversarialParserFixtures

    private let oid = String(repeating: "a", count: 40)
    /// `bad\xFF\xFE.txt`, the invalid UTF-8 name in the fixtures.
    private let invalidName = Data("bad".utf8) + Data([0xFF, 0xFE]) + Data(".txt".utf8)
    private var statusHeader: String { "# branch.oid \(oid)\u{0}# branch.head main\u{0}" }

    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func path(_ text: String) -> GitPath { GitPath(text) }

    private func assertFails<T>(
        _ parser: String,
        _ expression: @autoclosure () throws -> T,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
            XCTAssertEqual((error as? ParseError)?.parser, parser, message, file: file, line: line)
        }
    }

    // MARK: - §12 file names with spaces, line feeds and tabs

    func test_PAR_STATUS_10_realOutputKeepsHostileNamesVerbatim() throws {
        let state = try StatusParser.parse(Fixtures.status)
        XCTAssertEqual(
            state.unstaged.map(\.path.raw),
            [data("--"), data("-dash.txt"), data(":(exclude)x"), invalidName, data("line\nbreak.txt")]
        )
        XCTAssertEqual(state.unstaged.map(\.status), [.modified, .modified, .modified, .deleted, .modified])
        XCTAssertEqual(
            state.staged,
            [
                FileChange(path: GitPath(raw: invalidName), status: .added),
                FileChange(
                    path: path("new\nname.txt"), originalPath: path("old name.txt"), status: .renamed(score: 100)),
            ]
        )
        XCTAssertEqual(
            state.untracked.map(\.path.raw),
            [data("e\u{301}te\u{301}.txt"), data(#"quote"back\slash.txt"#), data("tab\there.txt"), data("🌳 grove.txt")]
        )
        XCTAssertEqual(state.skippedRecords, 0)
        XCTAssertFalse(state.isPartial)
    }

    /// With `-z` a path is the rest of its token, so text that looks like a header or a record stays a path.
    func test_PAR_STATUS_10_recordLookalikePathsStayPaths() throws {
        let fakeRecord = "1 M. N... 100644 100644 100644 \(oid) \(oid) evil"
        let input =
            statusHeader + "? # branch.head evil\u{0}"
            + "2 R. N... 100644 100644 100644 \(oid) \(oid) R100 new\n# stash 9\u{0}\(fakeRecord)\u{0}" + "x\u{0}"
        let state = try StatusParser.parse(data(input))
        XCTAssertEqual(state.head, .branch("main"))
        XCTAssertEqual(state.stashCount, 0)
        XCTAssertEqual(state.untracked.map(\.path.display), ["# branch.head evil"])
        XCTAssertEqual(
            state.staged,
            [FileChange(path: path("new\n# stash 9"), originalPath: path(fakeRecord), status: .renamed(score: 100))]
        )
        XCTAssertEqual(state.skippedRecords, 1, "`x` is an unknown record kind")
    }

    func test_PAR_WT_06_realOutputKeepsHostilePathsAndLockReason() throws {
        let worktrees = try WorktreeParser.parse(Fixtures.worktree).worktrees
        XCTAssertEqual(
            worktrees.map(\.path.display),
            ["/tmp/dev/repo", "/tmp/dev/wt/-dash", "/tmp/dev/wt/line\nbreak", "/tmp/dev/wt/my repo"]
        )
        XCTAssertEqual(worktrees.map(\.isMain), [true, false, false, false])
        XCTAssertEqual(worktrees.map(\.branch), ["refs/heads/main", nil, "refs/heads/feat/58-x", nil])
        XCTAssertEqual(worktrees.map(\.isDetached), [false, true, false, true], "PAR-WT-02 from real output")
        XCTAssertEqual(worktrees.map(\.lock), [.unlocked, .unlocked, .unlocked, .locked(reason: "on usb\ndrive")])
    }

    func test_PAR_WT_06_lineFeedThenAttributeTextStaysInPath() throws {
        let input = data("worktree /tmp/dev/x\nbranch refs/heads/evil\nlocked\u{0}HEAD \(oid)\u{0}detached\u{0}\u{0}")
        let worktree = try XCTUnwrap(try WorktreeParser.parse(input).worktrees.first)
        XCTAssertEqual(worktree.path.display, "/tmp/dev/x\nbranch refs/heads/evil\nlocked")
        XCTAssertNil(worktree.branch)
        XCTAssertTrue(worktree.isDetached)
        XCTAssertEqual(worktree.lock, .unlocked)
    }

    func test_PAR_NUMSTAT_01_realOutputKeepsHostileNamesVerbatim() throws {
        XCTAssertEqual(
            try NumstatParser.parseCommitFiles(Fixtures.numstat).files,
            [
                FileStat(path: path("-bin.dat"), status: .added, added: nil, deleted: nil),
                FileStat(path: path(":(exclude)x"), status: .modified, added: 2, deleted: 0),
                FileStat(path: GitPath(raw: invalidName), status: .added, added: 1, deleted: 0),
                FileStat(path: path("line\nbreak.txt"), status: .modified, added: 2, deleted: 0),
                FileStat(
                    path: path("new\nname.txt"),
                    originalPath: path("old name.txt"),
                    status: .renamed(score: 100),
                    added: 0,
                    deleted: 0
                ),
            ]
        )
        let stash = try NumstatParser.parseStashFiles(Fixtures.stashShow).files
        XCTAssertEqual(stash.map(\.path.raw), [data("-dash.txt"), invalidName, data("new\nname.txt")])
        XCTAssertEqual(stash.map(\.originalPath), [nil, nil, path("old name.txt")])
    }

    /// Counts are read by position: a path made of `-` and tabs is still the path, not a binary marker.
    func test_PAR_NUMSTAT_01_countLookalikePathsStayPaths() throws {
        let input = data("-\t-\t-\u{0}1\t2\t-\t-\u{0}0\t0\t--\u{0}")
        XCTAssertEqual(
            try NumstatParser.parseStashFiles(input).files,
            [
                FileStat(path: path("-"), added: nil, deleted: nil),
                FileStat(path: path("-\t-"), added: 1, deleted: 2),
                FileStat(path: path("--"), added: 0, deleted: 0),
            ]
        )
    }

    func test_PAR_STASH_02_realOutputKeepsHostileSubjects() throws {
        let stashes = try StashParser.parse(Fixtures.stash).stashes
        XCTAssertEqual(stashes.map(\.index), [0, 1])
        XCTAssertEqual(stashes.map(\.branch), ["main", "main"])
        XCTAssertEqual(stashes.map(\.message), ["한글 🌳 line", #"exp: try -dash "q""#])

        let lineFeed = data("stash@{0}\u{0}\(oid)\u{0}On main: a\nb\u{0}1793853652\u{0}")
        let stash = try XCTUnwrap(try StashParser.parse(lineFeed).stashes.first)
        XCTAssertNil(stash.branch, "the subject pattern does not match across a line feed")
        XCTAssertEqual(stash.message, "On main: a\nb", "shown verbatim instead")
    }

    /// Real refs: names git allows but `FullRefName` refuses (`-odd`, `-lead`) are skipped and counted instead of being
    /// decoded into something git would read as an option; `(detached)` is an ordinary branch here; `gone` is real.
    func test_PAR_REF_04_realOutputKeepsHostileNamesAndSkipsUnusableOnes() throws {
        let listing = try RefParser.parse(Fixtures.refs)
        XCTAssertEqual(
            listing.branches.map(\.fullName),
            [
                "refs/heads/(detached)", "refs/heads/(initial)", "refs/heads/feat/58-x", "refs/heads/main",
                "refs/heads/한글/🌳-name", "refs/remotes/origin/HEAD", "refs/remotes/origin/main",
            ]
        )
        XCTAssertEqual(listing.tags.map(\.fullName), ["refs/tags/v1-🌳"])
        XCTAssertEqual(listing.skippedRecords, 2, "refs/heads/-odd and refs/tags/-lead")
        XCTAssertNotNil(listing.tags.first?.peeledTarget)
        XCTAssertEqual(listing.branches.filter(\.isHead).map(\.fullName), ["refs/heads/main"])
        XCTAssertEqual(
            listing.branches.map(\.upstreamStatus),
            [
                .none, .none, .gone(upstream: "refs/remotes/origin/missing"),
                .tracking(upstream: "refs/remotes/origin/main", ahead: 1, behind: 0), .none, .none, .none,
            ]
        )
        XCTAssertEqual(listing.branches.compactMap(\.symbolicTarget), ["refs/remotes/origin/main"])
        XCTAssertTrue(listing.branches.allSatisfy { FullRefName($0.fullName) != nil })
        XCTAssertEqual(try RevListParser.parse(Fixtures.revList), RevListParser.Counts(behind: 0, ahead: 1))
    }

    // MARK: - §12 NFD/NFC

    func test_PAR_STATUS_10_realNFDNameIsNotNormalizedAndRoundTrips() throws {
        let nfd = try XCTUnwrap(try StatusParser.parse(Fixtures.status).untracked.first?.path)
        XCTAssertEqual(nfd.raw, data("e\u{301}te\u{301}.txt"))
        XCTAssertNotEqual(nfd, path("\u{E9}t\u{E9}.txt"), "Swift `String ==` ignores normalization; `GitPath` must not")
        let argument = try XCTUnwrap(nfd.argument)
        XCTAssertEqual(Data(argument.utf8), nfd.raw, "the argument sent back to git has the same bytes")
    }

    // MARK: - §12 names starting with `-`, `--`, and pathspec magic

    func test_PAR_STATUS_10_dashAndMagicNamesGoBackAfterDoubleDash() throws {
        let state = try StatusParser.parse(Fixtures.status)
        XCTAssertEqual(
            state.unstaged.map(\.path.pathspecArguments),
            [["--", "--"], ["--", "-dash.txt"], ["--", ":(exclude)x"], nil, ["--", "line\nbreak.txt"]]
        )
        XCTAssertTrue(GitEnvironment.commonArguments.contains("--literal-pathspecs"), "`:(exclude)x` stays literal")
    }

    /// `git update-ref refs/heads/-odd` creates such a branch and status prints it as is (Apple Git 2.50.1). The parser
    /// keeps the name; `FullRefName` refuses it, so it can never reach git as an option.
    func test_PAR_STATUS_10_dashBranchIsKeptButNeverUsableAsRef() throws {
        let state = try StatusParser.parse(data("# branch.oid \(oid)\u{0}# branch.head -odd\u{0}"))
        XCTAssertEqual(state.head, .branch("-odd"))
        let input = data("worktree /tmp/dev/repo\u{0}HEAD \(oid)\u{0}branch refs/heads/-odd\u{0}\u{0}")
        let branch = try XCTUnwrap(try WorktreeParser.parse(input).worktrees.first?.branch)
        XCTAssertEqual(branch, "refs/heads/-odd")
        XCTAssertNil(FullRefName(branch))
    }

    // MARK: - §12 invalid UTF-8

    func test_PAR_STATUS_13_realInvalidUTF8PathInEveryPathParser() throws {
        let status = try StatusParser.parse(Fixtures.status)
        let paths =
            status.staged.map(\.path) + status.unstaged.map(\.path)
            + (try NumstatParser.parseCommitFiles(Fixtures.numstat).files.map(\.path))
            + (try NumstatParser.parseStashFiles(Fixtures.stashShow).files.map(\.path))
        let invalid = paths.filter { $0.raw == invalidName }
        XCTAssertEqual(invalid.count, 4, "status staged add and unstaged delete, commit add, stash")
        for path in invalid {
            XCTAssertFalse(path.isRepresentable)
            XCTAssertNil(path.pathspecArguments, "file-level actions are off")
            XCTAssertEqual(path.display, "bad\u{FFFD}\u{FFFD}.txt")
        }
    }

    func test_PAR_CONFIG_05_invalidUTF8DriverNameFailsClosed() throws {
        let input = data("local\u{0}filter.") + Data([0xFF]) + data(".clean\ncat\u{0}")
        let listing = try ConfigParser.parse(input)
        let driver = try XCTUnwrap(listing.entries.first?.subsection)
        XCTAssertFalse(ConfigParser.isNeutralizableDriverName(driver))
        XCTAssertNil(RepoConfigInspector.inspect(listing).safetyContext, "queries are blocked")
    }

    // MARK: - §12 detached HEAD

    /// git allows a branch named `(detached)`, and status then prints the same header as for a detached HEAD
    /// (Apple Git 2.50.1). The status header alone cannot tell them apart; the worktree listing can.
    func test_PAR_STATUS_03_branchNamedDetachedIsOnlyDistinguishableInWorktreeListing() throws {
        let state = try StatusParser.parse(data("# branch.oid \(oid)\u{0}# branch.head (detached)\u{0}"))
        XCTAssertEqual(state.head, .detached)
        let input = data("worktree /tmp/dev/repo\u{0}HEAD \(oid)\u{0}branch refs/heads/(detached)\u{0}\u{0}")
        let worktree = try XCTUnwrap(try WorktreeParser.parse(input).worktrees.first)
        XCTAssertFalse(worktree.isDetached)
        XCTAssertEqual(worktree.branch, "refs/heads/(detached)")
    }

    // MARK: - §12 upstream missing or gone

    func test_PAR_STATUS_04_upstreamHeadersInAnyOrderAndHostileValues() throws {
        let reordered = try StatusParser.parse(
            data("# branch.ab +2 -3\u{0}" + statusHeader + "# branch.upstream origin/main\u{0}"))
        XCTAssertEqual(reordered.upstream, .tracking(upstream: "origin/main", ahead: 2, behind: 3))

        let bad = [
            "# branch.ab +99999999999999999999 -0", "# branch.ab +1 -0 ", "# branch.ab -1 +0", "# branch.ab +1  -0",
            "# branch.ab + -0", "# branch.ab +１ -0", "# branch.upstream ", "# stash -1", "# stash 99999999999999999999",
            "# stash ０",
        ]
        for header in bad {
            assertFails("StatusParser", try StatusParser.parse(data(statusHeader + header + "\u{0}")), header)
        }
    }

    // MARK: - §12 empty repository, unborn branch

    func test_PAR_STATUS_02_emptyAndLoneNULInputPerParser() throws {
        for truncated in [false, true] {
            XCTAssertEqual(try WorktreeParser.parse(Data(), truncated: truncated).worktrees, [])
            XCTAssertEqual(try StashParser.parse(Data(), truncated: truncated).stashes, [])
            XCTAssertEqual(try LogParser.parseGraph(Data(), truncated: truncated).commits, [])
            XCTAssertEqual(try ConfigParser.parse(Data(), truncated: truncated).entries, [])
            XCTAssertEqual(try NumstatParser.parseCommitFiles(Data(), truncated: truncated).files, [])
            XCTAssertEqual(try NumstatParser.parseStashFiles(Data(), truncated: truncated).files, [])
            XCTAssertEqual(try RefParser.parse(Data(), truncated: truncated).branches, [])
            assertFails("StatusParser", try StatusParser.parse(Data(), truncated: truncated), "no branch headers")
            assertFails("LogParser", try LogParser.parseCommitMeta(Data(), truncated: truncated), "no commit")
        }
        let loneNUL = Data([0])
        assertFails("WorktreeParser", try WorktreeParser.parse(loneNUL))
        assertFails("StatusParser", try StatusParser.parse(loneNUL))
        assertFails("StashParser", try StashParser.parse(loneNUL))
        assertFails("LogParser", try LogParser.parseGraph(loneNUL))
        assertFails("LogParser", try LogParser.parseCommitMeta(loneNUL))
        assertFails("ConfigParser", try ConfigParser.parse(loneNUL))
        assertFails("NumstatParser", try NumstatParser.parseCommitFiles(loneNUL))
        assertFails("NumstatParser", try NumstatParser.parseStashFiles(loneNUL))
        assertFails("RefParser", try RefParser.parse(loneNUL))
        assertFails("RefParser", try RefParser.parse(Data([0x0A])), "lone LF")
        assertFails("RevListParser", try RevListParser.parse(Data()))
        assertFails("RevListParser", try RevListParser.parse(Data([0x0A])))
    }

    // MARK: - §12 submodules

    func test_PAR_STATUS_11_submoduleInRenameConflictAndNumstat() throws {
        let input =
            statusHeader + "2 R. SC.. 160000 160000 160000 \(oid) \(oid) R100 new-sub\u{0}old-sub\u{0}"
            + "u UU SC.. 160000 160000 160000 160000 \(oid) \(oid) \(oid) conflicted-sub\u{0}"
        let state = try StatusParser.parse(data(input))
        XCTAssertEqual(
            state.staged,
            [
                FileChange(
                    path: path("new-sub"), originalPath: path("old-sub"), status: .renamed(score: 100),
                    isSubmodule: true)
            ]
        )
        XCTAssertEqual(
            state.conflicted,
            [FileChange(path: path("conflicted-sub"), status: .conflicted(.bothModified), isSubmodule: true)]
        )

        let other = String(repeating: "b", count: 40)
        let numstat = data(":160000 160000 \(oid) \(other) M\u{0}sub\u{0}1\t1\tsub\u{0}")
        XCTAssertEqual(
            try NumstatParser.parseCommitFiles(numstat).files,
            [FileStat(path: path("sub"), status: .modified, added: 1, deleted: 1)]
        )
    }

    // MARK: - §12 SHA-256 repositories

    func test_PAR_LOG_04_objectIDLengthAndCaseInEveryParser() {
        let bad =
            [39, 41, 63, 65].map { String(repeating: "a", count: $0) }
            + ["A", "g"].map { String(repeating: $0, count: 40) } + [String(repeating: "A", count: 64)]
        for value in bad {
            assertFails(
                "WorktreeParser", try WorktreeParser.parse(data("worktree /r\u{0}HEAD \(value)\u{0}\u{0}")), value)
            assertFails("StatusParser", try StatusParser.parse(data("# branch.oid \(value)\u{0}# branch.head m\u{0}")))
            assertFails(
                "StatusParser",
                try StatusParser.parse(data(statusHeader + "1 M. N... 100644 100644 100644 \(value) \(oid) p\u{0}")),
                value
            )
            assertFails("StashParser", try StashParser.parse(data("stash@{0}\u{0}\(value)\u{0}On m: s\u{0}1\u{0}")))
            assertFails(
                "LogParser", try LogParser.parseGraph(data("\(value)\u{0}\u{0}t\u{0}t\u{0}1\u{0}s\u{0}\u{0}")), value)
            assertFails(
                "LogParser", try LogParser.parseGraph(data("\(oid)\u{0}\(value)\u{0}t\u{0}t\u{0}1\u{0}s\u{0}\u{0}")))
            assertFails(
                "NumstatParser",
                try NumstatParser.parseCommitFiles(data(":100644 100644 \(value) \(oid) M\u{0}p\u{0}1\t0\tp\u{0}")),
                value
            )
            assertFails(
                "RefParser", try RefParser.parse(data("refs/heads/x\u{0}\(value)\u{0}\u{0}\u{0} \u{0}\u{0}\u{0}\n")))
        }
    }

    // MARK: - §12 NUL in a commit message

    /// git cuts a message at its first NUL (PAR-LOG-08). If an extra NUL ever got through, the parsers must fail instead
    /// of shifting fields onto the next record, even when the token count still divides evenly.
    func test_PAR_LOG_08_extraNULNeverShiftsFields() {
        let record = { (subject: String) in
            "\(self.oid)\u{0}\u{0}t\u{0}t@example.com\u{0}1793853652\u{0}\(subject)\u{0}\u{0}"
        }
        let oneExtra = record("before\u{0}after") + record("next")
        // Seven extra NULs keep the token count a multiple of the seven graph fields.
        let sevenExtra = record("a\u{0}b\u{0}c\u{0}d\u{0}e\u{0}f\u{0}g\u{0}h") + record("next")
        for input in [oneExtra, sevenExtra] {
            for truncated in [false, true] {
                assertFails("LogParser", try LogParser.parseGraph(data(input), truncated: truncated))
            }
        }
        let detail = "\(oid)\u{0}\u{0}t\u{0}t@example.com\u{0}1\u{0}t\u{0}t@example.com\u{0}1\u{0}before\u{0}after\u{0}"
        assertFails("LogParser", try LogParser.parseCommitMeta(data(detail)))

        let stash = { (subject: String) in "stash@{0}\u{0}\(self.oid)\u{0}\(subject)\u{0}1793853652\u{0}" }
        assertFails("StashParser", try StashParser.parse(data(stash("On main: a\u{0}b") + stash("On main: c"))))
        assertFails(
            "StashParser", try StashParser.parse(data(stash("On main: a\u{0}b\u{0}c\u{0}d\u{0}e") + stash("x"))))
        let ref = "refs/heads/a\u{0}b\u{0}\(oid)\u{0}\u{0}\u{0} \u{0}1\u{0}\u{0}\n"
        assertFails("RefParser", try RefParser.parse(data(ref)), "a NUL in a ref name adds a field")
    }

    // MARK: - §1.5 / §1.6 structure

    /// Output that was not cut must end with its terminator (NUL, or LF for refs and rev-list); a missing one is a
    /// format violation in every parser, never a silently accepted last record.
    func test_PAR_PROP_01_missingFinalNULFailsWithoutTruncation() {
        assertFails("WorktreeParser", try WorktreeParser.parse(Fixtures.worktree.dropLast()))
        assertFails("StatusParser", try StatusParser.parse(Fixtures.status.dropLast()))
        assertFails("StashParser", try StashParser.parse(Fixtures.stash.dropLast()))
        assertFails("LogParser", try LogParser.parseGraph(LogParserFixtures.sha1Graph.dropLast()))
        assertFails("LogParser", try LogParser.parseCommitMeta(LogParserFixtures.sha1Detail.dropLast()))
        assertFails("ConfigParser", try ConfigParser.parse(Fixtures.config.dropLast()))
        assertFails("ConfigParser", try ConfigParser.parse(data("local\u{0}x.flag")), "valueless boolean")
        assertFails("NumstatParser", try NumstatParser.parseCommitFiles(Fixtures.numstat.dropLast()))
        assertFails("NumstatParser", try NumstatParser.parseStashFiles(Fixtures.stashShow.dropLast()))
        assertFails("RefParser", try RefParser.parse(Fixtures.refs.dropLast()))
        assertFails("RevListParser", try RevListParser.parse(Fixtures.revList.dropLast()))
    }
}
