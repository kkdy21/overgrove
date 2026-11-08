import XCTest

@testable import Overgrove

/// Issue links from branch names and commit subjects (#82, parsing-spec.md §11.3).
final class IssueLinkTests: XCTestCase {
    private static let tip = ObjectID(String(repeating: "a", count: 40))!
    private static let other = ObjectID(String(repeating: "b", count: 40))!

    static func branch(_ full: String, _ kind: Branch.Kind = .local, target: ObjectID = tip, symbolic: String? = nil)
        -> Branch
    {
        Branch(
            fullName: full, kind: kind, target: target, upstreamStatus: .none, isHead: false, committerDate: nil,
            symbolicTarget: symbolic)
    }

    static func listing(_ branches: [Branch]) -> WorktreeListing {
        var listing = WorktreeListing.mockup
        listing.refs = RefParser.Listing(branches: branches, tags: [], isPartial: false, skippedRecords: 0)
        return listing
    }

    static func commit(_ index: Int, _ subject: String) -> CommitNode {
        CommitNode(
            oid: ObjectID(String(format: "%040x", index + 1))!, parents: [], authorName: "a", authorEmail: "a@x",
            authorDate: Date(timeIntervalSince1970: 0), subject: subject)
    }

    func testWorktreesAndBranchesLinkByName() {
        let index = IssueLinkIndex(
            listing: Self.listing([
                Self.branch("refs/heads/feat/42-rate-limit"),
                Self.branch("refs/heads/12-docs", target: Self.other),
                Self.branch("refs/remotes/origin/feat/12-docs", .remote(remote: "origin")),
                Self.branch("refs/remotes/origin/fix/7-crash", .remote(remote: "origin")),
                Self.branch(
                    "refs/remotes/origin/HEAD", .remote(remote: "origin"), symbolic: "refs/remotes/origin/main"),
                Self.branch("refs/heads/main"),
            ]))
        // The mockup's `feat/42-rate-limit` worktree.
        XCTAssertEqual(index.links(42).worktrees.map(\.title), ["feat/42-rate-limit"])
        XCTAssertEqual(index.links(42).branches.map(\.title), ["feat/42-rate-limit"])
        XCTAssertEqual(index.kind(42), .worktree)
        // Local before remote.
        XCTAssertEqual(index.links(12).branches.map(\.title), ["12-docs", "origin/feat/12-docs"])
        XCTAssertEqual(index.links(12).branches.first?.target, Self.other)
        XCTAssertEqual(index.kind(12), .branch)
        // A remote branch alone shows in LINKED but does not mark the issue row.
        XCTAssertEqual(index.links(7).branches.map(\.isRemote), [true])
        XCTAssertNil(index.kind(7))
        XCTAssertNil(index.kind(99))
        XCTAssertTrue(index.links(99).branches.isEmpty)
    }

    func testBranchTitlesAreEscaped() {
        let index = IssueLinkIndex(listing: Self.listing([Self.branch("refs/heads/feat/5-\u{202E}x")]))
        XCTAssertFalse(index.links(5).branches[0].title.unicodeScalars.contains("\u{202E}"))
    }

    /// SEC-T15-11: a remote that pushes thousands of `feat/1-*` refs keeps LINKED (and the graph outline) small.
    func testLinksPerIssueAreLimited() {
        let many =
            (0..<500).map { Self.branch("refs/remotes/origin/feat/1-\($0)", .remote(remote: "origin")) }
            + (0..<30).map { Self.branch("refs/heads/feat/1-\($0)") }
        let links = IssueLinkIndex(listing: Self.listing(many)).links(1)
        let limit = IssueLinkIndex.limitPerKind
        XCTAssertEqual(links.branches.filter { !$0.isRemote }.count, limit)
        XCTAssertEqual(links.branches.filter(\.isRemote).count, limit)
        XCTAssertEqual(links.hiddenCount, 530 - 2 * limit)
        XCTAssertEqual(IssueLinkIndex(listing: Self.listing(many)).kind(1), .branch)
        let detail = IssueDetailModel(IssueModelsTests.issue(1), repository: nil, links: links)
        XCTAssertEqual(detail.hiddenLinkCount, 510)
    }

    /// A configured remote named like an issue branch (`x/99-y`) is cut off before the branch rule runs.
    func testConfiguredRemoteNamesAreCutExactly() {
        var listing = Self.listing([Self.branch("refs/remotes/x/99-y/main", .remote(remote: "x"))])
        listing.remoteNames = ["x/99-y"]
        XCTAssertTrue(IssueLinkIndex(listing: listing).links(99).branches.isEmpty)
        listing.remoteNames = []
        XCTAssertEqual(IssueLinkIndex(listing: listing).links(99).branches.count, 1, "unconfigured: first segment only")
    }

    func testWorktreeTitlesAreEscaped() {
        var listing = WorktreeListing.mockup
        listing.refs = nil
        let entry = WorktreeListing.entry("/tmp/dev/api-wt/x", branch: "feat/8-\u{202E}x", state: .missing)
        listing = WorktreeListing(entries: listing.entries + [entry], isPartial: false)
        let title = IssueLinkIndex(listing: listing).links(8).worktrees.first?.title ?? ""
        XCTAssertFalse(title.unicodeScalars.contains("\u{202E}"))
        XCTAssertFalse(title.isEmpty)
    }

    /// Only the start of a subject is scanned (git does not cut subjects).
    func testLongSubjectsAreScannedOnlyAtTheStart() {
        let padding = String(repeating: "x ", count: CommitLink.subjectScanLimit)
        XCTAssertEqual(CommitLink.issueNumbers(in: "#4 " + padding, repository: nil), [4])
        XCTAssertEqual(CommitLink.issueNumbers(in: padding + " #4", repository: nil), [])
        let slice = [Self.commit(0, "#4 a"), Self.commit(1, "#4 b")][1...]
        XCTAssertEqual(CommitLink.latest(linkedTo: 4, in: slice, repository: nil).map(\.subject), ["#4 b"])
    }

    func testLatestCommitsReferenceTheIssue() {
        let commits = [
            Self.commit(0, "fix: keep (#12)"), Self.commit(1, "feat: C#12 support"), Self.commit(2, "team/app#12 x"),
            Self.commit(3, "evil/app#12 x"), Self.commit(4, "#12 a"), Self.commit(5, "#12 b"), Self.commit(6, "#12 c"),
            Self.commit(7, "#12 d"),
        ]
        let links = CommitLink.latest(linkedTo: 12, in: commits, repository: "team/app")
        XCTAssertEqual(links.map(\.subject), ["fix: keep (#12)", "team/app#12 x", "#12 a", "#12 b", "#12 c"])
        XCTAssertEqual(links.first?.shortSHA, commits[0].oid.short)
        XCTAssertEqual(
            CommitLink.latest(linkedTo: 12, in: commits, repository: nil).map(\.subject).count, 5,
            "without a repository, owner/repo#n never counts")
        XCTAssertFalse(
            CommitLink.latest(linkedTo: 3, in: [Self.commit(0, "#3 \u{2028}x")], repository: nil)[0].subject
                .unicodeScalars.contains("\u{2028}"))
    }

    func testLinkedIssuesComeFirst() {
        let index = IssueLinkIndex(listing: Self.listing([Self.branch("refs/heads/12-docs")]))
        let model = IssueListModel(
            content: .loaded(
                repository: .github(IssueModelsTests.repository),
                issues: [
                    IssueModelsTests.issue(12, updated: 0), IssueModelsTests.issue(42, updated: 10),
                    IssueModelsTests.issue(50, updated: 20),
                ]),
            isLoading: false, links: index)
        XCTAssertEqual(model.rows.map(\.id), [42, 12, 50])
        XCTAssertEqual(model.rows.map(\.linkKind), [.worktree, .branch, nil])
        XCTAssertTrue(model.rows[0].accessibilityLabel.hasSuffix("linked worktree"))
    }

    func testDetailListsLinkedItems() {
        let index = IssueLinkIndex(listing: Self.listing([Self.branch("refs/heads/feat/42-rate-limit")]))
        let commits = CommitLink.latest(linkedTo: 42, in: [Self.commit(0, "feat: limit (#42)")], repository: nil)
        let detail = IssueDetailModel(
            IssueModelsTests.issue(42), repository: IssueModelsTests.repository, links: index.links(42),
            commits: commits)
        XCTAssertEqual(detail.linkedWorktrees.map(\.path), [GitPath("/tmp/dev/api-wt/42-rate-limit")])
        XCTAssertEqual(detail.linkedBranches.map(\.title), ["feat/42-rate-limit"])
        XCTAssertEqual(detail.linkedCommits.map(\.subject), ["feat: limit (#42)"])
    }

    func testWorktreeAndLocalBranchRowsCarryTheNumber() {
        let worktrees = WorktreeListModel(listing: .mockup, focused: nil)
        XCTAssertEqual(
            worktrees.rows.first { $0.title == "feat/42-rate-limit" }?.issueNumber, 42)
        XCTAssertNil(worktrees.rows.first { $0.title == "main" }?.issueNumber)
        XCTAssertTrue(
            worktrees.rows.first { $0.title == "feat/42-rate-limit" }?.accessibilityLabel.hasSuffix("issue 42") ?? false
        )

        let refs = RefParser.Listing(
            branches: [
                Self.branch("refs/heads/fix/7-crash"),
                Self.branch("refs/remotes/origin/fix/7-crash", .remote(remote: "origin")),
            ], tags: [], isPartial: false, skippedRecords: 0)
        let model = BranchListModel(refs: refs, checkedOut: [], remoteNames: ["origin"])
        func rows(_ nodes: [BranchNode]) -> [BranchRow] {
            nodes.flatMap { node -> [BranchRow] in
                switch node {
                case .branch(let row): [row]
                case .folder(_, _, _, let children): rows(children)
                }
            }
        }
        XCTAssertEqual(rows(model.local).map(\.issueNumber), [7])
        XCTAssertEqual(rows(model.remote).map(\.issueNumber), [nil], "remote rows show no issue badge")
    }
}
