import Foundation
import XCTest

@testable import Overgrove

/// PAR-STATUS-01…15 (parsing-spec.md §3).
final class StatusParserTests: XCTestCase {
    /// Real output of `git status --porcelain=v2 -z --branch --show-stash --untracked-files=all
    /// --ignore-submodules=dirty` (git 2.54.0) for a worktree with upstream `origin/trunk` (+1 -0), two stashes,
    /// staged M/A/D/R, an `MM` file, unstaged M/D/T, and file names with a line feed, a space, a tab, a leading
    /// `-`, `--`, `:(exclude)x`, NFD `été` (git prints it as NFC) and Hangul.
    private let realOutput = Data(
        base64Encoded:
            "IyBicmFuY2gub2lkIDRiODJkMzg0YTY3YjJhOGIzYjQ1YWFhMTJiNmYwM2IwN2M0MDljMjQAIyBicmFuY2guaGVhZCB0cnVuawAjIGJyYW5jaC"
            + "51cHN0cmVhbSBvcmlnaW4vdHJ1bmsAIyBicmFuY2guYWIgKzEgLTAAIyBzdGFzaCAyADEgLk0gTi4uLiAxMDA2NDQgMTAwNjQ0IDEwMDY0NCA1"
            + "ODdiZTZiNGMzZjkzZjkzYzQ4OWMwMTExYmJhNTU5NjE0N2EyNmNiIDU4N2JlNmI0YzNmOTNmOTNjNDg5YzAxMTFiYmE1NTk2MTQ3YTI2Y2IgLS"
            + "0AMSAuTSBOLi4uIDEwMDY0NCAxMDA2NDQgMTAwNjQ0IDU4N2JlNmI0YzNmOTNmOTNjNDg5YzAxMTFiYmE1NTk2MTQ3YTI2Y2IgNTg3YmU2YjRj"
            + "M2Y5M2Y5M2M0ODljMDExMWJiYTU1OTYxNDdhMjZjYiAtZGFzaC50eHQAMSAuTSBOLi4uIDEwMDY0NCAxMDA2NDQgMTAwNjQ0IDU4N2JlNmI0Yz"
            + "NmOTNmOTNjNDg5YzAxMTFiYmE1NTk2MTQ3YTI2Y2IgNTg3YmU2YjRjM2Y5M2Y5M2M0ODljMDExMWJiYTU1OTYxNDdhMjZjYiA6KGV4Y2x1ZGUp"
            + "eAAxIC5NIE4uLi4gMTAwNjQ0IDEwMDY0NCAxMDA2NDQgNTg3YmU2YjRjM2Y5M2Y5M2M0ODljMDExMWJiYTU1OTYxNDdhMjZjYiA1ODdiZTZiNG"
            + "MzZjkzZjkzYzQ4OWMwMTExYmJhNTU5NjE0N2EyNmNiIGxpbmUKYnJlYWsudHh0ADIgUi4gTi4uLiAxMDA2NDQgMTAwNjQ0IDEwMDY0NCBkZjk2"
            + "N2I5NmE1NzllNDVhMThiODI1MTczMmQxNjgwNGIyZTU2YTU1IGRmOTY3Yjk2YTU3OWU0NWExOGI4MjUxNzMyZDE2ODA0YjJlNTZhNTUgUjEwMC"
            + "BuZXctbmFtZS50eHQAb2xkLW5hbWUudHh0ADEgQS4gTi4uLiAwMDAwMDAgMTAwNjQ0IDEwMDY0NCAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAw"
            + "MDAwMDAwMDAwMDAwMDAwIDc4OTgxOTIyNjEzYjJhZmI2MDI1MDQyZmY2YmQ4NzhhYzE5OTRlODUgc3RhZ2VkLWFkZGVkLnR4dAAxIE1NIE4uLi"
            + "4gMTAwNjQ0IDEwMDY0NCAxMDA2NDQgZGY5NjdiOTZhNTc5ZTQ1YTE4YjgyNTE3MzJkMTY4MDRiMmU1NmE1NSBiZjllNTE2NzAzODIzMGMzNDE2"
            + "OTJiYTg5ZDI5YjI3Zjk1YjljZDdlIHN0YWdlZC1hbmQtdW5zdGFnZWQudHh0ADEgRC4gTi4uLiAxMDA2NDQgMDAwMDAwIDAwMDAwMCBkZjk2N2"
            + "I5NmE1NzllNDVhMThiODI1MTczMmQxNjgwNGIyZTU2YTU1IDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAgc3RhZ2Vk"
            + "LWRlbGV0ZWQudHh0ADEgTS4gTi4uLiAxMDA2NDQgMTAwNjQ0IDEwMDY0NCA0NTliYjEwYjQ3ZjM0M2FmZTc2NWMzN2UxNmU0ZjIwNTc0NjI2Ym"
            + "VkIDgyYzBlOWU0NmZhZDU1YmYwNzNiZWM1ZDE1MGJmZjQ0OTExMWU0NTggc3RhZ2VkLW1vZGlmaWVkLnR4dAAxIC5UIE4uLi4gMTIwMDAwIDEy"
            + "MDAwMCAxMDA2NDQgN2RhMTgwNmI2MDQyZDQwNGJhMGMyZjY4MjA1MGMxMTJhMjE4OGVmMiA3ZGExODA2YjYwNDJkNDA0YmEwYzJmNjgyMDUwYz"
            + "ExMmEyMTg4ZWYyIHR5cGVjaGFuZ2UAMSAuRCBOLi4uIDEwMDY0NCAxMDA2NDQgMDAwMDAwIGRmOTY3Yjk2YTU3OWU0NWExOGI4MjUxNzMyZDE2"
            + "ODA0YjJlNTZhNTUgZGY5NjdiOTZhNTc5ZTQ1YTE4YjgyNTE3MzJkMTY4MDRiMmU1NmE1NSB1bnN0YWdlZC1kZWxldGVkLnR4dAAxIC5NIE4uLi"
            + "4gMTAwNjQ0IDEwMDY0NCAxMDA2NDQgZGY5NjdiOTZhNTc5ZTQ1YTE4YjgyNTE3MzJkMTY4MDRiMmU1NmE1NSBkZjk2N2I5NmE1NzllNDVhMThi"
            + "ODI1MTczMmQxNjgwNGIyZTU2YTU1IHVuc3RhZ2VkLW1vZGlmaWVkLnR4dAAxIC5NIE4uLi4gMTAwNjQ0IDEwMDY0NCAxMDA2NDQgNTg3YmU2Yj"
            + "RjM2Y5M2Y5M2M0ODljMDExMWJiYTU1OTYxNDdhMjZjYiA1ODdiZTZiNGMzZjkzZjkzYzQ4OWMwMTExYmJhNTU5NjE0N2EyNmNiIHdpdGggc3Bh"
            + "Y2UudHh0AD8gdGFiCWhlcmUudHh0AD8gdW50cmFja2VkIGRpci9uZXN0ZWQudHh0AD8gdW50cmFja2VkLnR4dAA/IMOpdMOpLnR4dAA/IO2VnO"
            + "q4gCDtjIzsnbwudHh0AA=="
    )!

    /// Real output (git 2.54.0) after a merge with both-added, both-modified, deleted-by-them and deleted-by-us.
    private let realConflictOutput = Data(
        ("# branch.oid 8ee7c30a2323ab1267e5af854d140e0806dc88a6\u{0}# branch.head trunk\u{0}"
            + "u AA N... 000000 100644 100644 100644 0000000000000000000000000000000000000000 "
            + "351be5bf6e17c59ea560546d69654115ecb2fd8d e45c9c2666d44e0327c1f9c239a74c508336053e both-added.txt\u{0}"
            + "u UU N... 100644 100644 100644 100644 df967b96a579e45a18b8251732d16804b2e56a55 "
            + "351be5bf6e17c59ea560546d69654115ecb2fd8d e45c9c2666d44e0327c1f9c239a74c508336053e both-modified.txt\u{0}"
            + "u UD N... 100644 100644 000000 100644 df967b96a579e45a18b8251732d16804b2e56a55 "
            + "351be5bf6e17c59ea560546d69654115ecb2fd8d 0000000000000000000000000000000000000000 deleted-by-them.txt\u{0}"
            + "u DU N... 100644 000000 100644 100644 df967b96a579e45a18b8251732d16804b2e56a55 "
            + "0000000000000000000000000000000000000000 e45c9c2666d44e0327c1f9c239a74c508336053e deleted-by-us.txt\u{0}")
            .utf8
    )

    /// Real output (git 2.54.0) for a submodule whose checked-out commit moved and whose files are dirty.
    /// `--ignore-submodules=dirty` hides the dirty part, so only `C` is reported.
    private let realSubmoduleOutput = Data(
        ("# branch.oid 3638058f0dcc30ee269749470bf76418f1685248\u{0}# branch.head trunk\u{0}"
            + "1 .M SC.. 160000 160000 160000 65ba591dfd1401939e56df2cf841069a85193d76 "
            + "65ba591dfd1401939e56df2cf841069a85193d76 mod\u{0}").utf8
    )

    private let oid = String(repeating: "a", count: 40)
    private let zeroOID = String(repeating: "0", count: 40)
    private var header: String { "# branch.oid \(oid)\u{0}# branch.head main\u{0}" }

    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func ordinary(_ xy: String, _ path: String, sub: String = "N...") -> String {
        "1 \(xy) \(sub) 100644 100644 100644 \(oid) \(oid) \(path)\u{0}"
    }

    private func renamed(_ xy: String, _ score: String, _ path: String, from original: String) -> String {
        "2 \(xy) N... 100644 100644 100644 \(oid) \(oid) \(score) \(path)\u{0}\(original)\u{0}"
    }

    private func unmerged(_ xy: String, _ path: String) -> String {
        "u \(xy) N... 100644 100644 100644 100644 \(oid) \(oid) \(oid) \(path)\u{0}"
    }

    private func assertParseFails(
        _ input: Data,
        _ message: String = "",
        truncated: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try StatusParser.parse(input, truncated: truncated), message, file: file, line: line) {
            XCTAssertEqual(($0 as? ParseError)?.parser, "StatusParser", file: file, line: line)
        }
    }

    // MARK: - Headers

    func test_PAR_STATUS_01_realOutputBranchUpstreamAndChanges() throws {
        let state = try StatusParser.parse(realOutput)
        XCTAssertEqual(state.headCommit, ObjectID("4b82d384a67b2a8b3b45aaa12b6f03b07c409c24"))
        XCTAssertEqual(state.head, .branch("trunk"))
        XCTAssertEqual(state.upstream, .tracking(upstream: "origin/trunk", ahead: 1, behind: 0))
        XCTAssertEqual(state.stashCount, 2)
        XCTAssertFalse(state.isPartial)
        XCTAssertEqual(state.skippedRecords, 0)

        XCTAssertEqual(
            state.staged.map { "\($0.status.code) \($0.path)" },
            [
                "R new-name.txt", "A staged-added.txt", "M staged-and-unstaged.txt", "D staged-deleted.txt",
                "M staged-modified.txt",
            ]
        )
        XCTAssertEqual(
            state.unstaged.map { "\($0.status.code) \($0.path)" },
            [
                "M --", "M -dash.txt", "M :(exclude)x", "M line\nbreak.txt", "M staged-and-unstaged.txt",
                "T typechange",
                "D unstaged-deleted.txt", "M unstaged-modified.txt", "M with space.txt",
            ]
        )
        XCTAssertEqual(
            state.untracked.map(\.path.display),
            ["tab\there.txt", "untracked dir/nested.txt", "untracked.txt", "\u{E9}t\u{E9}.txt", "한글 파일.txt"]
        )
        XCTAssertTrue(state.untracked.allSatisfy { $0.status == .untracked })
        XCTAssertTrue(state.conflicted.isEmpty)
    }

    func test_PAR_STATUS_02_initialBranchHasNoHeadCommit() throws {
        let input = "# branch.oid (initial)\u{0}# branch.head trunk\u{0}" + ordinary("A.", "a.txt")
        let state = try StatusParser.parse(data(input))
        XCTAssertNil(state.headCommit)
        XCTAssertEqual(state.head, .branch("trunk"))
        XCTAssertEqual(state.staged.map(\.status), [.added])
    }

    func test_PAR_STATUS_03_detachedHead() throws {
        let state = try StatusParser.parse(data("# branch.oid \(oid)\u{0}# branch.head (detached)\u{0}"))
        XCTAssertEqual(state.head, .detached)
        XCTAssertEqual(state.headCommit, ObjectID(oid))
        XCTAssertEqual(state.upstream, .none)
        XCTAssertTrue(state.isClean)
    }

    func test_PAR_STATUS_04_upstreamWithoutAheadBehindIsGone() throws {
        let state = try StatusParser.parse(data(header + "# branch.upstream origin/vanished\u{0}"))
        XCTAssertEqual(state.upstream, .gone(upstream: "origin/vanished"))
    }

    func test_PAR_STATUS_05_noUpstream() throws {
        let state = try StatusParser.parse(data(header))
        XCTAssertEqual(state.upstream, .none)
        XCTAssertEqual(state.stashCount, 0, "no `# stash` header means no stashes")
    }

    func test_PAR_STATUS_05_aheadBehindParsesBothSigns() throws {
        let input = header + "# branch.upstream origin/main\u{0}# branch.ab +12 -345\u{0}"
        let state = try StatusParser.parse(data(input))
        XCTAssertEqual(state.upstream, .tracking(upstream: "origin/main", ahead: 12, behind: 345))
    }

    func test_PAR_STATUS_05_malformedAheadBehindFails() {
        for ab in ["1 -0", "+1 0", "+1", "+x -0", "+1 -0 +2", "-1 +0", "+1  -0", "+ -0", "+1 --0"] {
            assertParseFails(data(header + "# branch.upstream origin/main\u{0}# branch.ab \(ab)\u{0}"))
        }
    }

    func test_PAR_STATUS_06_stashCount() throws {
        XCTAssertEqual(try StatusParser.parse(data(header + "# stash 7\u{0}")).stashCount, 7)
        assertParseFails(data(header + "# stash seven\u{0}"))
        assertParseFails(data(header + "# stash -1\u{0}"))
    }

    // MARK: - Records

    func test_PAR_STATUS_07_bothSidesChangedAppearsInBothLists() throws {
        let state = try StatusParser.parse(realOutput)
        let path = GitPath("staged-and-unstaged.txt")
        XCTAssertEqual(state.staged.filter { $0.path == path }.map(\.status), [.modified])
        XCTAssertEqual(state.unstaged.filter { $0.path == path }.map(\.status), [.modified])
        XCTAssertEqual(state.changedPathCount, 18, "the MM file is counted once")
    }

    func test_PAR_STATUS_08_renameRecordHasOriginalPathField() throws {
        let rename = try XCTUnwrap(try StatusParser.parse(realOutput).staged.first { $0.status.code == "R" })
        XCTAssertEqual(rename.path, GitPath("new-name.txt"), "-z prints the new path first")
        XCTAssertEqual(rename.originalPath, GitPath("old-name.txt"))
        XCTAssertEqual(rename.status, .renamed(score: 100))
    }

    func test_PAR_STATUS_08_copyAndWorktreeRename() throws {
        let input =
            header + renamed("C.", "C75", "copy.txt", from: "source.txt")
            + renamed(".R", "R90", "moved.txt", from: "intent.txt")
            + renamed("RM", "R100", "edited.txt", from: "before.txt")
        let state = try StatusParser.parse(data(input))
        XCTAssertEqual(
            state.staged,
            [
                FileChange(path: GitPath("copy.txt"), originalPath: GitPath("source.txt"), status: .copied(score: 75)),
                FileChange(
                    path: GitPath("edited.txt"), originalPath: GitPath("before.txt"), status: .renamed(score: 100)),
            ]
        )
        XCTAssertEqual(
            state.unstaged,
            [
                FileChange(
                    path: GitPath("moved.txt"), originalPath: GitPath("intent.txt"), status: .renamed(score: 90)),
                FileChange(path: GitPath("edited.txt"), status: .modified),
            ],
            "the original path belongs to the side that renamed"
        )
    }

    func test_PAR_STATUS_08_malformedRenameRecordFails() {
        assertParseFails(data(header + "2 R. N... 100644 100644 100644 \(oid) \(oid) R100 only-new.txt\u{0}"))
        assertParseFails(data(header + renamed("R.", "X100", "a", from: "b")))
        assertParseFails(data(header + renamed("R.", "R1x", "a", from: "b")))
        assertParseFails(data(header + renamed("M.", "R100", "a", from: "b")), "a `2` record must rename or copy")
        assertParseFails(data(header + renamed("R.", "C100", "a", from: "b")), "score letter must match XY")
    }

    func test_PAR_STATUS_09_allSevenConflictKinds() throws {
        let kinds = ConflictKind.allCases
        let input = header + kinds.map { unmerged($0.rawValue, "\($0.rawValue).txt") }.joined()
        let state = try StatusParser.parse(data(input))
        XCTAssertEqual(state.conflicted.map(\.status), kinds.map { .conflicted($0) })
        XCTAssertEqual(state.conflicted.map(\.path.display), kinds.map { "\($0.rawValue).txt" })
        XCTAssertTrue(state.staged.isEmpty && state.unstaged.isEmpty, "conflicts are not also staged or unstaged")
    }

    func test_PAR_STATUS_09_realConflictOutput() throws {
        let state = try StatusParser.parse(realConflictOutput)
        XCTAssertEqual(
            state.conflicted.map(\.status),
            [
                .conflicted(.bothAdded), .conflicted(.bothModified), .conflicted(.deletedByThem),
                .conflicted(.deletedByUs),
            ]
        )
        XCTAssertEqual(
            state.conflicted.map(\.path.display),
            ["both-added.txt", "both-modified.txt", "deleted-by-them.txt", "deleted-by-us.txt"]
        )
    }

    func test_PAR_STATUS_09_unknownConflictXYFails() {
        assertParseFails(data(header + unmerged("MM", "x.txt")))
        assertParseFails(data(header + "u UU N... 100644 100644 100644 100644 \(oid) \(oid) x.txt\u{0}"))
    }

    func test_PAR_STATUS_10_specialFileNamesKeepRawBytes() throws {
        let state = try StatusParser.parse(realOutput)
        let unstaged = Set(state.unstaged.map(\.path.display))
        XCTAssertTrue(unstaged.isSuperset(of: ["--", "-dash.txt", ":(exclude)x", "with space.txt"]))
        XCTAssertTrue(state.unstaged.contains { $0.path.display == "line\nbreak.txt" })
        XCTAssertTrue(state.untracked.contains { $0.path.display == "tab\there.txt" })

        let nfd = "e\u{301}te\u{301}.txt"
        let nfdState = try StatusParser.parse(
            data(header + "? \(nfd)\u{0}? \(nfd.precomposedStringWithCanonicalMapping)\u{0}"))
        XCTAssertEqual(nfdState.untracked.map(\.path.raw), [Data(nfd.utf8), Data("\u{E9}t\u{E9}.txt".utf8)])
        XCTAssertNotEqual(nfdState.untracked[0].path, nfdState.untracked[1].path, "no Unicode normalization")
    }

    func test_PAR_STATUS_10_pathKeepsSpacesAfterFixedFields() throws {
        let state = try StatusParser.parse(data(header + ordinary(".M", "  two  leading spaces ") + "?  x\u{0}"))
        XCTAssertEqual(state.unstaged.map(\.path.display), ["  two  leading spaces "])
        XCTAssertEqual(state.untracked.map(\.path.display), [" x"])
    }

    func test_PAR_STATUS_11_submodules() throws {
        let state = try StatusParser.parse(realSubmoduleOutput)
        XCTAssertEqual(state.unstaged, [FileChange(path: GitPath("mod"), status: .modified, isSubmodule: true)])

        let synthetic = try StatusParser.parse(data(header + ordinary(".M", "sub", sub: "S.M.")))
        XCTAssertEqual(synthetic.unstaged.map(\.isSubmodule), [true])
        XCTAssertEqual(try StatusParser.parse(realOutput).unstaged.filter(\.isSubmodule), [])
    }

    func test_PAR_STATUS_11_malformedSubmoduleFieldFails() {
        for sub in ["X...", "N..", "S.M.X", "SX..", "N.M."] {
            assertParseFails(data(header + ordinary(".M", "sub", sub: sub)), sub)
        }
    }

    func test_PAR_STATUS_12_typeChange() throws {
        let state = try StatusParser.parse(data(header + ordinary("T.", "staged-link") + ordinary(".T", "link")))
        XCTAssertEqual(state.staged.map(\.status), [.typeChanged])
        XCTAssertEqual(state.unstaged.map(\.status), [.typeChanged])
    }

    func test_PAR_STATUS_12_intentToAddIsUnstagedAdded() throws {
        let input = header + "1 .A N... 000000 000000 100644 \(zeroOID) \(zeroOID) intent.txt\u{0}"
        let state = try StatusParser.parse(data(input))
        XCTAssertEqual(state.unstaged.map(\.status), [.added])
        XCTAssertTrue(state.staged.isEmpty)
    }

    func test_PAR_STATUS_13_invalidUTF8PathIsNotRepresentable() throws {
        var input = data(header + "? bad")
        input.append(contentsOf: [0xFF, 0xFE])
        input.append(data(".txt\u{0}"))
        let path = try XCTUnwrap(try StatusParser.parse(input).untracked.first?.path)
        XCTAssertFalse(path.isRepresentable)
        XCTAssertNil(path.argument)
        XCTAssertEqual(path.raw, Data([0x62, 0x61, 0x64, 0xFF, 0xFE, 0x2E, 0x74, 0x78, 0x74]), "raw bytes kept")
    }

    // MARK: - Structure

    func test_PAR_STATUS_14_truncatedOutputDropsLastRecord() throws {
        let full = data(header + ordinary("M.", "a.txt") + ordinary("M.", "b.txt"))
        let cut = try StatusParser.parse(full.prefix(full.count - 3), truncated: true)
        XCTAssertEqual(cut.staged.map(\.path.display), ["a.txt"])
        XCTAssertTrue(cut.isPartial)

        let atBoundary = try StatusParser.parse(full, truncated: true)
        XCTAssertEqual(atBoundary.staged.map(\.path.display), ["a.txt"], "the last record is never trusted")
        XCTAssertTrue(atBoundary.isPartial)
    }

    func test_PAR_STATUS_14_truncatedInsideRenameOriginalPath() throws {
        let full = data(header + ordinary("M.", "a.txt") + renamed("R.", "R100", "new.txt", from: "old.txt"))
        for cutBytes in [1, 3, "old.txt\u{0}".utf8.count, "old.txt\u{0}".utf8.count + 2] {
            let state = try StatusParser.parse(full.prefix(full.count - cutBytes), truncated: true)
            XCTAssertEqual(state.staged.map(\.path.display), ["a.txt"], "cut \(cutBytes) bytes")
        }
    }

    func test_PAR_STATUS_14_untruncatedOutputMustBeComplete() {
        let full = data(header + ordinary("M.", "a.txt"))
        assertParseFails(full.prefix(full.count - 1), "missing final NUL without the truncated flag")
        assertParseFails(data(header + "1 M. N... 100644 100644 100644 \(oid) \(oid)\u{0}"))
    }

    func test_PAR_STATUS_15_unknownHeadersIgnoredUnknownRecordsCounted() throws {
        let input =
            "# branch.future x\u{0}" + header + "# something new\u{0}#\u{0}" + "! ignored.log\u{0}"
            + "Z future record\u{0}" + ordinary(".M", "kept.txt") + "9\u{0}"
        let state = try StatusParser.parse(data(input))
        XCTAssertEqual(state.skippedRecords, 2, "`!` is expected noise, not an unknown kind")
        XCTAssertEqual(state.unstaged.map(\.path.display), ["kept.txt"])
        XCTAssertEqual(state.head, .branch("main"))
    }

    func test_malformedFieldsFailWholeParser() {
        let badOID = "1 M. N... 100644 100644 100644 \(oid) XYZ path\u{0}"
        let badMode = "1 M. N... 100644 10064x 100644 \(oid) \(oid) path\u{0}"
        let shortMode = "1 M. N... 10064 100644 100644 \(oid) \(oid) path\u{0}"
        let badXY = "1 Q. N... 100644 100644 100644 \(oid) \(oid) path\u{0}"
        let renameInOrdinary = "1 R. N... 100644 100644 100644 \(oid) \(oid) path\u{0}"
        let doubleSpace = "1 M.  N... 100644 100644 100644 \(oid) \(oid) path\u{0}"
        let emptyPath = "1 M. N... 100644 100644 100644 \(oid) \(oid) \u{0}"
        for record in [
            badOID, badMode, shortMode, badXY, renameInOrdinary, doubleSpace, emptyPath, "? \u{0}", "?x\u{0}",
        ] {
            assertParseFails(data(header + record), record)
        }
        assertParseFails(data(header + "\u{0}" + ordinary("M.", "a")), "empty token")
    }

    func test_malformedBranchHeadersFail() {
        assertParseFails(data("# branch.oid nothex\u{0}# branch.head main\u{0}"))
        assertParseFails(data("# branch.oid \(oid)\u{0}"), "missing branch.head")
        assertParseFails(data("# branch.oid \(oid)\u{0}# branch.head \u{0}"), "empty branch.head")
        assertParseFails(data(""), "empty output has no branch headers")
    }

    func test_sha256ObjectIDs() throws {
        let long = String(repeating: "b", count: 64)
        let input =
            "# branch.oid \(long)\u{0}# branch.head main\u{0}1 M. N... 100644 100644 100644 \(long) \(long) a\u{0}"
        let state = try StatusParser.parse(data(input))
        XCTAssertEqual(state.headCommit?.isSHA256, true)
        XCTAssertEqual(state.staged.count, 1)
    }

    func test_errorOffsetPointsAtFailingRecord() {
        let prefix = header + ordinary("M.", "a")
        let input = data(prefix + "1 Q. N... 100644 100644 100644 \(oid) \(oid) b\u{0}")
        XCTAssertThrowsError(try StatusParser.parse(input)) {
            XCTAssertEqual(($0 as? ParseError)?.offset, prefix.utf8.count)
        }
    }

    // MARK: - Size

    func test_longPathAndManyRecords() throws {
        let longPath = String(repeating: "d/", count: 2047) + "ff"
        XCTAssertEqual(longPath.utf8.count, 4096)
        XCTAssertEqual(
            try StatusParser.parse(data(header + "? \(longPath)\u{0}")).untracked.first?.path.display, longPath)

        let records = (0..<100_000).map { ordinary("MM", "src/file-\($0).swift") }.joined()
        let input = data(header + records)
        let start = Date()
        let state = try StatusParser.parse(input)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(state.staged.count, 100_000)
        XCTAssertEqual(state.unstaged.count, 100_000)
        XCTAssertLessThan(elapsed, 1.0, "100k records must parse within 1 s (test-strategy.md §4.1)")
    }
}
