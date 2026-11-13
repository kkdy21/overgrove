import XCTest

@testable import Overgrove

/// The detail panel's header names what the panel shows (#578): a comparison before the WIP or commit behind it,
/// and a mark for each kind of selection.
final class DetailHeaderTests: XCTestCase {
    private let author = CommitDetailModel.Person(
        name: "Alice Example", email: "alice@example.com", initials: "AE", avatarIndex: 3)

    func testEachSelectionHasItsMark() {
        typealias Subject = DetailHeader.Subject
        XCTAssertEqual(
            DetailHeader(Subject(commit: ("a91f3c2", author, 2))),
            DetailHeader(title: "Commit a91f3c2", mark: .commit(initials: "AE", avatarIndex: 3, laneIndex: 2)))
        XCTAssertEqual(DetailHeader(Subject(issueNumber: "#82")), DetailHeader(title: "#82", mark: .issue))
        XCTAssertEqual(DetailHeader(Subject(stashRef: "stash@{0}")), DetailHeader(title: "stash@{0}", mark: .stash))
        XCTAssertEqual(
            DetailHeader(Subject(worktreeTitle: "fix/57-token-refresh", worktreeLane: 4)),
            DetailHeader(title: "fix/57-token-refresh", mark: .worktree(laneIndex: 4)))
        XCTAssertEqual(
            DetailHeader(Subject(worktreeTitle: "detached")).mark, .worktree(laneIndex: nil), "a neutral tile")
        XCTAssertEqual(DetailHeader(Subject()), DetailHeader(title: "No selection", mark: .none))
    }

    /// S-11 and S-12 cover the WIP or the commit the panel had before; the header names the comparison instead.
    func testAComparisonNamesWhatItCompares() {
        let behind = DetailHeader.Subject(
            commit: ("a91f3c2", author, 2), worktreeTitle: "fix/57-token-refresh", worktreeLane: 4)
        var withBranch = behind
        withBranch.comparisonBase = "main"
        XCTAssertEqual(DetailHeader(withBranch), DetailHeader(title: "Changes vs main", mark: .comparison))
        var withCommits = behind
        withCommits.commitComparisonTitle = "3c5d6f1 → a91f3c2"
        XCTAssertEqual(DetailHeader(withCommits), DetailHeader(title: "3c5d6f1 → a91f3c2", mark: .comparison))
    }

    /// The same order as the panel's content: a commit before an issue, an issue before a stash, all before the WIP.
    func testTheOrderFollowsTheContent() {
        let all = DetailHeader.Subject(
            commit: ("a91f3c2", author, 2), issueNumber: "#82", stashRef: "stash@{0}", worktreeTitle: "main")
        XCTAssertEqual(DetailHeader(all).mark, .commit(initials: "AE", avatarIndex: 3, laneIndex: 2))
        var noCommit = all
        noCommit.commit = nil
        XCTAssertEqual(DetailHeader(noCommit).mark, .issue)
        noCommit.issueNumber = nil
        XCTAssertEqual(DetailHeader(noCommit).mark, .stash)
    }
}
