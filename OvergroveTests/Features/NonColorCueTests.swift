import XCTest

@testable import Overgrove

/// Status is never told by colour alone (interaction.md §6.2, iconography.md §5, #37).
///
/// Increase Contrast swaps the colours (the High Contrast colour-set variants, checked in `TokensTests`); the symbols,
/// arrows, and letters below come from the models, which take no appearance or contrast input, so they stay the same
/// in every mode. These tests pin them so a later change cannot leave a state with colour as its only cue.
final class NonColorCueTests: XCTestCase {
    // MARK: File status (S-02 group headers and rows, iconography.md §5.1)

    func testChangeGroupsHaveTheirOwnSymbolAndTitle() {
        let expected: [WorkingChangeGroup: String] = [
            .staged: "checkmark.circle.fill", .unstaged: "pencil", .untracked: "questionmark.circle",
            .conflicted: "exclamationmark.triangle.fill",
        ]
        for (group, symbol) in expected {
            XCTAssertEqual(group.symbol, symbol, "\(group)")
            XCTAssertFalse(group.title.isEmpty, "\(group)")
        }
        let groups = WorkingChangeGroup.allCases
        XCTAssertEqual(Set(groups), Set(expected.keys), "every group is pinned")
        XCTAssertEqual(Set(groups.map(\.symbol)).count, groups.count, "groups shown together differ in silhouette")
    }

    /// The change-kind badge is a letter, and VoiceOver reads a word, whatever the badge's fill colour.
    func testEveryChangeKindHasALetterAndAWord() {
        let kinds: [FileChange.Status] =
            [.modified, .typeChanged, .added, .deleted, .renamed(score: 90), .copied(score: 80), .untracked]
            + ConflictKind.allCases.map(FileChange.Status.conflicted)
        for kind in kinds {
            XCTAssertFalse(String(kind.code).trimmingCharacters(in: .whitespaces).isEmpty, "\(kind)")
            XCTAssertFalse(WipDetailModel.kindName(kind).isEmpty, "\(kind)")
        }
        let distinct: [FileChange.Status] =
            [.modified, .typeChanged, .added, .deleted, .renamed(score: nil), .copied(score: nil), .untracked]
        XCTAssertEqual(Set(distinct.map(\.code)).count, distinct.count, "one letter per kind")
        let conflictWords = ConflictKind.allCases.map { WipDetailModel.kindName(.conflicted($0)) }
        XCTAssertEqual(Set(conflictWords).count, ConflictKind.allCases.count, "each unmerged state reads differently")
    }

    // MARK: Worktree badges (sidebar, iconography.md §5.2)

    func testEveryWorktreeBadgeHasASymbolOrAnArrow() {
        let badges: [WorktreeRow.Badge] = [.conflicts(2), .prunable, .changed(3), .ahead(1), .behind(4), .locked]
        for badge in badges {
            XCTAssertTrue(badge.symbol != nil || badge.text?.first.map("↑↓".contains) == true, "\(badge)")
        }
        XCTAssertEqual(WorktreeRow.Badge.conflicts(2).symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(WorktreeRow.Badge.prunable.symbol, "questionmark.folder")
        XCTAssertEqual(WorktreeRow.Badge.changed(3).symbol, "pencil")
        XCTAssertEqual(WorktreeRow.Badge.locked.symbol, "lock.fill")
        let symbols = badges.compactMap(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count, "badges shown together differ in silhouette")
    }

    /// Ahead and behind share a colour on purpose; the direction is the meaning (iconography.md §5.2).
    func testAheadAndBehindDifferByDirection() {
        XCTAssertEqual(WorktreeRow.Badge.ahead(2).text, "↑2")
        XCTAssertEqual(WorktreeRow.Badge.behind(2).text, "↓2")
        XCTAssertNil(WorktreeRow.Badge.ahead(2).symbol)
        XCTAssertEqual(WorktreeRow.Badge.conflicts(1_200).text, "999+", "counts keep their cap")
        XCTAssertNil(WorktreeRow.Badge.locked.text)
    }
}
