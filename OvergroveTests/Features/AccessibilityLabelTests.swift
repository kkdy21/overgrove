import SwiftUI
import XCTest

@testable import Overgrove

/// What VoiceOver reads for rows built today (interaction.md §6.1, #75): states and kinds as words, refs and HEAD
/// spelled out, nothing carried by color or glyphs alone. Rotors, focus order, and announcements need a person with
/// VoiceOver (docs/qa/checklist.md QA-A11Y, #96).
final class AccessibilityLabelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func commit(parents: Int = 1, minutesAgo: Double = 120) -> CommitNode {
        CommitNode(
            oid: ObjectID(String(repeating: "a", count: 40))!,
            parents: (0..<parents).map { ObjectID(String(repeating: "\($0 + 1)", count: 40))! }, authorName: "Ko",
            authorEmail: "ko@example.com", authorDate: now.addingTimeInterval(-minutesAgo * 60),
            subject: "feat: add status parser")
    }

    private func pill(_ kind: GraphRefPill.Kind, _ title: String, remote: Bool = false) -> GraphRefPill {
        GraphRefPill(kind: kind, title: title, hasMatchingRemote: remote, tooltip: title)
    }

    func testGraphRowReadsSHASubjectAuthorTimeRefsAndHead() {
        let commit = commit()
        let label = GraphRowAccessibility.label(
            commit: commit, text: GraphCommitText(commit, now: now),
            pills: [pill(.focusedBranch, "feat/12", remote: true), pill(.tag, "v0.1.0")], isHead: true, now: now)
        XCTAssertEqual(
            label,
            "Commit aaaaaaa, feat: add status parser, Ko, 2 hours ago, branches feat/12 and origin/feat/12, "
                + "tag v0.1.0, HEAD of worktree feat/12")
    }

    func testMergeCommitsIssuesAndHighlightAreRead() {
        let merge = commit(parents: 2, minutesAgo: 3)
        let label = GraphRowAccessibility.label(
            commit: merge, text: GraphCommitText(merge, now: now), pills: [], isHead: true, linkedIssues: [12, 40],
            isHighlighted: true, now: now)
        XCTAssertTrue(
            label.hasSuffix(
                "3 minutes ago, HEAD of the focused worktree, merge commit, 2 parents, issue 12, 40, "
                    + "linked to the selected issue"), label)
        XCTAssertFalse(GraphRowAccessibility.hint(merge).isEmpty, "the absolute date is the hint")
    }

    /// #706: the row's relative time follows the app's language like the rest of the label; it was fixed to English.
    func testGraphRowTimeIsReadInTheAppLanguage() {
        let twoHoursAgo = now.addingTimeInterval(-7_200)
        XCTAssertEqual(GraphRowAccessibility.relative(twoHoursAgo, now: now), "2 hours ago", "the tests' language")
        XCTAssertEqual(
            GraphRowAccessibility.relative(twoHoursAgo, now: now, locale: Locale(identifier: "ko")), "2시간 전")
        XCTAssertEqual(
            GraphRowAccessibility.relative(now.addingTimeInterval(-20), now: now), "just now",
            "under a minute, as S-04 and the TAGS rows read it")
    }

    /// #710: the absolute date in the hint follows the app's language too; it was fixed to English.
    func testGraphRowHintIsReadInTheAppLanguage() {
        let commit = commit()
        let english = GraphRowAccessibility.hint(commit)
        let korean = GraphRowAccessibility.hint(commit, locale: Locale(identifier: "ko"))
        XCTAssertTrue(english.contains("2027"), english)
        XCTAssertFalse(english.contains("년"), "the tests' language: \(english)")
        XCTAssertTrue(korean.contains("2027년"), korean)
        XCTAssertTrue(korean.contains("월"), korean)
        XCTAssertNotEqual(korean, english)
    }

    func testRefListsGroupBranchesTagsAndDetachedWorktrees() {
        XCTAssertEqual(
            GraphRowAccessibility.refs([
                pill(.localBranch, "main"), pill(.remoteBranch, "upstream/main"), pill(.worktreeBranch, "fix/x"),
                pill(.detachedWorktree, "review"), pill(.tag, "v1"), pill(.tag, "v2"),
            ]),
            ["branches main, upstream/main and fix/x", "tags v1 and v2", "detached worktree review"])
        XCTAssertEqual(GraphRowAccessibility.refs([]), [])
    }

    func testWipRowSpellsOutCountsWithoutGlyphs() throws {
        let state = WorktreeListing.state(branch: "feat", staged: 3, unstaged: 2, untracked: 1, conflicted: 1)
        let worktree = Worktree(
            path: GitPath("/tmp/dev/api-wt/feat-12"), head: ObjectID(String(repeating: "a", count: 40)),
            branch: "refs/heads/feat", isMain: false, isDetached: false, isBare: false, lock: .unlocked,
            isPrunable: false, prunableReason: nil)
        let row = try XCTUnwrap(GraphWipRow.make(worktree: worktree, state: state))
        XCTAssertEqual(
            row.accessibilityLabel,
            "Uncommitted changes in feat-12: 3 staged, 2 unstaged, 1 untracked, 1 conflicted")
        XCTAssertTrue(row.summary.contains("⚠"), "the visible summary keeps its glyph; VoiceOver gets words")
    }

    func testFileRowsInCommitStashAndComparisonReadKindPathAndLines() {
        let modified = CommitDetailModelTests.stat("Sources/Status.swift", .modified, 42, 8)
        XCTAssertEqual(
            WipDetailModel.fileAccessibilityLabel(modified), "Modified, Sources/Status.swift, 42 lines added, 8 removed"
        )

        let renamed = ComparisonModelTests.stat("src/new.txt", .renamed(score: 90), 1, 0, from: "src/old.txt")
        XCTAssertEqual(
            WipDetailModel.fileAccessibilityLabel(renamed, extras: ["also changed in the working tree"]),
            "Renamed, src/old.txt renamed to src/new.txt, also changed in the working tree, 1 line added, 0 removed")

        let stash = FileStat(path: GitPath("notes\u{202E}.txt"), added: nil, deleted: nil, isFromUntracked: true)
        XCTAssertEqual(
            WipDetailModel.fileAccessibilityLabel(stash, extras: ["from untracked files"]),
            "Notes\\u{202E}.txt, from untracked files, binary file", "no kind from numstat; escaped; binary in words")
    }

    func testWipFileRowsLeadWithTheGroup() {
        let label = WipDetailModel.fileAccessibilityLabel(
            leading: ["Conflicted", "both modified"], path: "a.go", original: nil, lineCount: nil)
        XCTAssertEqual(label, "Conflicted, both modified, a.go")
    }

    func testControlOutlinesThickenUnderIncreaseContrast() {
        XCTAssertEqual(Tokens.controlOutlineWidth(.standard), 1)
        XCTAssertEqual(Tokens.controlOutlineWidth(.increased), 1.5)
    }
}
