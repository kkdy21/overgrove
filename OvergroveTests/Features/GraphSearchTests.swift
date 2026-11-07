import XCTest

@testable import Overgrove

/// Toolbar search and the sidebar filter (#74).
final class GraphSearchTests: XCTestCase {
    private func commit(_ index: Int, _ subject: String, author: String = "Ko", email: String = "ko@example.com")
        -> CommitNode
    {
        CommitNode(
            // Distinct leading digits, so a SHA prefix names one commit.
            oid: ObjectID(String(format: "%02x", 0xa0 + index) + String(repeating: "0", count: 38))!, parents: [],
            authorName: author,
            authorEmail: email, authorDate: Date(timeIntervalSince1970: 0), subject: subject)
    }

    private func pill(_ title: String) -> GraphRefPill {
        GraphRefPill(kind: .localBranch, title: title, hasMatchingRemote: false, tooltip: "refs/heads/\(title)")
    }

    func testEmptyQueryIsNoSearch() {
        XCTAssertNil(GraphSearchQuery("   "))
        XCTAssertNil(GraphSearchQuery(""))
    }

    func testMatchesMessageAuthorShaRefAndIssue() throws {
        let commits = [
            commit(0, "feat: Rate limiter (#42)"), commit(1, "fix: crash", author: "Mina Lee", email: "mina@x.io"),
            commit(2, "docs: café"), commit(3, "chore: bump", author: "bot"), commit(4, "C#42 support"),
            commit(5, "#420 is another issue"),
        ]
        let pills = [commits[3].oid: [pill("feat/42-rate-limit")], commits[1].oid: [pill("release/1.0")]]
        func search(_ text: String) throws -> [Int] {
            let result = GraphSearchResult(
                query: try XCTUnwrap(GraphSearchQuery(text)), commits: commits, pills: pills, issueRepository: nil,
                isComplete: true)
            return result.matches.compactMap { oid in commits.firstIndex { $0.oid == oid } }
        }
        XCTAssertEqual(try search("rate LIMITER"), [0], "message, case-insensitive")
        XCTAssertEqual(try search("mina"), [1], "author name and email")
        XCTAssertEqual(try search("cafe"), [2], "diacritics ignored")
        XCTAssertEqual(try search(String(commits[1].oid.hex.prefix(8))), [1], "SHA prefix")
        XCTAssertEqual(try search("release"), [1], "ref name")
        XCTAssertEqual(try search("#42"), [0, 3], "subject reference and a branch named for it, not C#42 or #420")
    }

    func testSummaryAndStepping() throws {
        let commits = (0..<5).map { commit($0, $0.isMultiple(of: 2) ? "match \($0)" : "other") }
        let partial = GraphSearchResult(
            query: try XCTUnwrap(GraphSearchQuery("match")), commits: commits, pills: [:], issueRepository: nil,
            isComplete: false)
        XCTAssertEqual(partial.summary, "3 matches in 5 loaded commits · older commits are searched as they load")
        let none = GraphSearchResult(
            query: try XCTUnwrap(GraphSearchQuery("zzz")), commits: commits, pills: [:], issueRepository: nil,
            isComplete: true)
        XCTAssertEqual(none.summary, "No matches in all 5 commits")
        XCTAssertNil(none.step(from: nil, forward: true))

        let ids = partial.matches
        XCTAssertEqual(partial.step(from: nil, forward: true), ids[0])
        XCTAssertEqual(partial.step(from: nil, forward: false), ids[2])
        XCTAssertEqual(partial.step(from: ids[0], forward: true), ids[1])
        XCTAssertEqual(partial.step(from: ids[2], forward: true), ids[0], "wraps")
        XCTAssertEqual(partial.step(from: ids[0], forward: false), ids[2], "wraps back")
        XCTAssertEqual(partial.step(from: commits[1].oid, forward: true), ids[0], "not a match: starts over")
    }

    func testSidebarFilter() {
        XCTAssertNil(SidebarFilter.query("  "))
        XCTAssertTrue(SidebarFilter.matches(nil, "anything"))
        XCTAssertTrue(SidebarFilter.matches("FEAT", "feat/42", nil))
        XCTAssertFalse(SidebarFilter.matches("fix", "feat/42", nil))

        let refs = RefParser.Listing(
            branches: ["main", "feat/42-rate-limit", "feat/7-docs", "fix/9-crash"].map {
                Branch(
                    fullName: "refs/heads/\($0)", kind: .local, target: ObjectID(String(repeating: "a", count: 40))!,
                    upstreamStatus: .none, isHead: false, committerDate: nil, symbolicTarget: nil)
            }, tags: [], isPartial: false, skippedRecords: 0)
        let model = BranchListModel(refs: refs, checkedOut: [], remoteNames: [])
        let filtered = SidebarFilter.branches(model.local, query: "rate")
        XCTAssertEqual(filtered.count, 1)
        guard case .folder(_, let name, let count, let children) = filtered.first else { return XCTFail("folder") }
        XCTAssertEqual(name, "feat/")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(children.map(\.id), ["refs/heads/feat/42-rate-limit"])
        XCTAssertEqual(SidebarFilter.folderIDs(model.local), ["local/feat", "local/fix"])
        XCTAssertEqual(SidebarFilter.branches(model.local, query: nil), model.local)
    }
}
