import XCTest

@testable import Overgrove

/// The graph's author filter chips (screens.md S-01, #255).
final class GraphAuthorFilterTests: XCTestCase {
    private func commit(
        _ index: Int, author: String, email: String, coAuthors: [String] = []
    ) -> CommitNode {
        CommitNode(
            oid: ObjectID(String(format: "%040x", index + 1))!, parents: [], authorName: author, authorEmail: email,
            authorDate: Date(timeIntervalSince1970: 0), subject: "commit \(index)", coAuthors: coAuthors)
    }

    private let claude = "Claude <noreply@anthropic.com>"

    private var sample: [CommitNode] {
        [
            commit(0, author: "Alex Kim", email: "alex@example.com", coAuthors: [claude]),
            commit(1, author: "Mina Park", email: "mina@example.com"),
            commit(2, author: "alex kim", email: "ALEX@example.com "),
            commit(3, author: "Jordan Lee", email: "jordan@example.com"),
            commit(4, author: "Mina Park", email: "mina@example.com", coAuthors: [claude]),
            commit(5, author: "Alex Kim", email: "alex@example.com"),
            commit(6, author: "Bo", email: ""),
        ]
    }

    func testChipsAreCountedByAddressAndSortedByCount() {
        let summary = GraphAuthorSummary(commits: sample)
        XCTAssertEqual(summary.chips.map(\.name), ["Alex Kim", "Mina Park", "Bo", "Jordan Lee"])
        XCTAssertEqual(summary.chips.map(\.count), [3, 2, 1, 1])
        XCTAssertEqual(summary.chips[0].key, "alex@example.com", "address, trimmed and lowercased")
        XCTAssertEqual(summary.chips[0].initials, "AK")
        XCTAssertEqual(summary.chips[0].avatarIndex, AuthorAvatar.colorIndex(email: "alex@example.com"))
        XCTAssertEqual(summary.chips[2].key, "name:bo", "no address: keyed by name")
        XCTAssertEqual(summary.aiAssistedCount, 2)
        XCTAssertEqual(summary.tallied, 7)
        XCTAssertTrue(summary.hasChoices)
    }

    func testMoreThanFiveAuthorsFoldIntoTheOverflow() {
        let commits = (0..<8).map { commit($0, author: "Author \($0)", email: "a\($0)@example.com") }
        let summary = GraphAuthorSummary(commits: commits)
        XCTAssertEqual(summary.visibleChips.count, GraphAuthorSummary.visibleChipLimit)
        XCTAssertEqual(summary.overflowChips.map(\.name), ["Author 5", "Author 6", "Author 7"])
    }

    func testOneAuthorWithoutAIHasNothingToChoose() {
        let commits = (0..<3).map { commit($0, author: "Solo", email: "solo@example.com") }
        XCTAssertFalse(GraphAuthorSummary(commits: commits).hasChoices)
    }

    func testANewPageOnlyTalliesItsOwnCommits() {
        let all = sample
        let first = GraphAuthorSummary(commits: Array(all.prefix(3)))
        XCTAssertEqual(first.tallied, 3)
        let extended = first.extended(with: all)
        XCTAssertEqual(extended, GraphAuthorSummary(commits: all), "same result as tallying everything")
        XCTAssertEqual(extended.extended(with: all), extended, "nothing new: unchanged")
    }

    func testNamesAreEscapedAndCut() {
        let long = String(repeating: "x", count: 5_000)
        let summary = GraphAuthorSummary(commits: [
            commit(0, author: "Evil\u{202E}Name", email: "e@example.com"),
            commit(1, author: long, email: long + "@example.com"),
        ])
        XCTAssertFalse(summary.chips.contains { $0.name.unicodeScalars.contains("\u{202E}") }, "bidi controls escaped")
        XCTAssertTrue(summary.chips.allSatisfy { $0.key.count <= GraphAuthorSummary.fieldLimit + 5 })
        XCTAssertTrue(summary.chips.allSatisfy { $0.name.count <= GraphAuthorSummary.fieldLimit * 8 })
    }

    func testFilterPicksOutAnAuthorOrAIAssistedCommits() throws {
        let commits = sample
        XCTAssertNil(GraphAuthorFilterResult(selection: .all, commits: commits), "All: no filter")

        let alex = try XCTUnwrap(GraphAuthorFilterResult(selection: .author("alex@example.com"), commits: commits))
        XCTAssertEqual(alex.matchSet, Set([0, 2, 5].map { commits[$0].oid }))

        let ai = try XCTUnwrap(GraphAuthorFilterResult(selection: .aiAssisted, commits: commits))
        XCTAssertEqual(ai.matchSet, Set([0, 4].map { commits[$0].oid }))
    }

    func testFilterExtendsWithNewPages() throws {
        let commits = sample
        let first = try XCTUnwrap(
            GraphAuthorFilterResult(selection: .author("mina@example.com"), commits: Array(commits.prefix(2))))
        XCTAssertEqual(first.scanned, 2)
        let extended = first.extended(with: commits)
        XCTAssertEqual(extended, GraphAuthorFilterResult(selection: .author("mina@example.com"), commits: commits))
    }

    func testSearchRestrictedToTheFilterIsAnAnd() throws {
        let commits = sample
        let search = GraphSearchResult(
            query: try XCTUnwrap(GraphSearchQuery("commit")), commits: commits, pills: [:], issueRepository: nil,
            isComplete: false)
        let mina = try XCTUnwrap(GraphAuthorFilterResult(selection: .author("mina@example.com"), commits: commits))
        let both = search.restricted(to: mina.matchSet)
        XCTAssertEqual(both.matches, [commits[1].oid, commits[4].oid], "graph order kept")
        XCTAssertEqual(both.matchSet, Set(both.matches))
        XCTAssertEqual(
            both.summary, "2 matches in 7 loaded commits · older commits are searched as they load")
        XCTAssertEqual(both.step(from: commits[1].oid, forward: true), commits[4].oid)
    }

    func testAccessibilityLabel() {
        XCTAssertEqual(GraphAuthorSummary.accessibilityLabel(name: "Alex Kim", count: 1), "Alex Kim, 1 commit")
        XCTAssertEqual(GraphAuthorSummary.accessibilityLabel(name: "Alex Kim", count: 1_200), "Alex Kim, 1,200 commits")
    }
}
