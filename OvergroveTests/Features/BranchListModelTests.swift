import Foundation
import XCTest

@testable import Overgrove

/// `BranchListModel` (#72): information-architecture.md §4.2–§4.3 from cached refs, without views.
final class BranchListModelTests: XCTestCase {
    private let tip = ObjectID(String(repeating: "a", count: 40))!

    private func local(_ name: String, upstream: UpstreamStatus = .none) -> Branch {
        Branch(
            fullName: "refs/heads/\(name)", kind: .local, target: tip, upstreamStatus: upstream, isHead: false,
            committerDate: nil, symbolicTarget: nil)
    }

    private func remote(_ name: String, guess: String = "origin", symbolic: String? = nil, date: Date? = nil) -> Branch
    {
        Branch(
            fullName: "refs/remotes/\(name)", kind: .remote(remote: guess), target: tip, upstreamStatus: .none,
            isHead: false, committerDate: date, symbolicTarget: symbolic)
    }

    private func refs(_ branches: [Branch], skipped: Int = 0, partial: Bool = false) -> RefParser.Listing {
        RefParser.Listing(branches: branches, tags: [], isPartial: partial, skippedRecords: skipped)
    }

    private func names(_ nodes: [BranchNode]) -> [String] {
        nodes.map {
            switch $0 {
            case .branch(let row): row.name
            case .folder(_, let name, _, let children): "\(name)[\(names(children).joined(separator: ","))]"
            }
        }
    }

    /// §4.2: the default branch is pinned first; then `/` folders and loose names, each by name.
    func testLocalOrderAndFolders() {
        let model = BranchListModel(
            refs: refs([local("zeta"), local("feat/b"), local("main"), local("fix/x"), local("feat/a"), local("alpha")]
            ),
            checkedOut: [], remoteNames: ["origin"])
        XCTAssertEqual(names(model.local), ["main", "feat/[a,b]", "fix/[x]", "alpha", "zeta"])
        XCTAssertEqual(model.localCount, 6)
    }

    /// `origin/HEAD` names the default: the local branch tracking it wins over `main`.
    func testDefaultFollowsOriginHead() {
        let branches = [
            local("main"),
            local("trunk-local", upstream: .tracking(upstream: "refs/remotes/origin/trunk", ahead: 0, behind: 0)),
            remote("origin/HEAD", symbolic: "refs/remotes/origin/trunk"), remote("origin/trunk"),
        ]
        XCTAssertEqual(
            BranchListModel.defaultLocal(locals: branches.filter { $0.kind == .local }, symbolic: [branches[2]]),
            "refs/heads/trunk-local")
        XCTAssertEqual(
            BranchListModel.defaultLocal(locals: [local("master"), local("x")], symbolic: []), "refs/heads/master")
        XCTAssertNil(BranchListModel.defaultLocal(locals: [local("x")], symbolic: []))
    }

    func testBadgesAndStates() throws {
        let model = BranchListModel(
            refs: refs([
                local("main", upstream: .tracking(upstream: "refs/remotes/origin/main", ahead: 2, behind: 1)),
                local("old", upstream: .gone(upstream: "refs/remotes/origin/old")),
            ]),
            checkedOut: ["refs/heads/main"], remoteNames: ["origin"])
        guard case .branch(let main) = model.local[0], case .branch(let old) = model.local[1] else {
            return XCTFail("\(model.local)")
        }
        XCTAssertTrue(main.isDefault)
        XCTAssertTrue(main.isCheckedOut)
        XCTAssertEqual([main.ahead, main.behind], [2, 1])
        XCTAssertEqual(main.help, "main\nTracks origin/main  ↑2 ↓1\nChecked out in a worktree")
        XCTAssertEqual(main.accessibilityLabel, "main, local branch, default, checked out, 2 ahead, 1 behind")
        XCTAssertTrue(old.isUpstreamGone)
        XCTAssertEqual(old.help, "old\nUpstream origin/old is gone")
    }

    /// §4.2: remotes `origin` first then by name; `origin/HEAD` hidden; remote names with `/` follow the configured
    /// remotes instead of the parser's first-component guess.
    func testRemotesGroupingAndConfiguredNames() {
        let model = BranchListModel(
            refs: refs([
                remote("upstream/main", guess: "upstream"), remote("origin/HEAD", symbolic: "refs/remotes/origin/main"),
                remote("origin/main"), remote("origin/feat/42"), remote("team/a/dev", guess: "team"),
            ]),
            checkedOut: [], remoteNames: ["origin", "upstream", "team/a"])
        XCTAssertEqual(names(model.remote), ["origin[feat/[42],main]", "team/a[dev]", "upstream[main]"])
        XCTAssertEqual(model.remoteCount, 4, "origin/HEAD is not counted")

        // Without the configured remote, the parser's guess stands.
        let guessed = BranchListModel(
            refs: refs([remote("team/a/dev", guess: "team")]), checkedOut: [], remoteNames: [])
        XCTAssertEqual(names(guessed.remote), ["team[a/[dev]]"])
    }

    /// A combining mark right after `/` cannot hide the remote match and make a branch read like another
    /// (`origin/x`); an empty remainder shows the whole name (security review of #72).
    func testRemoteSplitIsByteExact() {
        let model = BranchListModel(
            refs: refs([remote("origin/\u{301}x"), remote("solo", guess: "solo")]), checkedOut: [],
            remoteNames: ["origin"])
        XCTAssertEqual(names(model.remote), ["origin[\u{301}x]", "solo[solo]"])
    }

    func testVisibleRowsFlattenOpenFolders() {
        let model = BranchListModel(
            refs: refs([local("main"), local("feat/a"), local("feat/b")]), checkedOut: [], remoteNames: [])
        XCTAssertEqual(BranchListModel.visibleRows(model.local, open: []).count, 2)
        let open = BranchListModel.visibleRows(model.local, open: ["local/feat"])
        XCTAssertEqual(open.map(\.depth), [0, 0, 1, 1])
    }

    func testNamesAreEscaped() throws {
        let model = BranchListModel(
            refs: refs([local("feat/x\u{202E}y"), remote("ori\u{2028}gin/b", guess: "ori\u{2028}gin")]),
            checkedOut: [], remoteNames: ["ori\u{2028}gin"])
        XCTAssertEqual(names(model.local), ["feat/[x\\u{202E}y]"])
        XCTAssertEqual(names(model.remote), ["ori\\u{2028}gin[b]"])
    }

    func testWarnings() {
        XCTAssertNil(BranchListModel(refs: refs([local("main")]), checkedOut: [], remoteNames: []).warning)
        XCTAssertEqual(
            BranchListModel(refs: refs([], skipped: 2), checkedOut: [], remoteNames: []).warning,
            "2 branches are not shown: the name is not valid UTF-8.")
        XCTAssertEqual(
            BranchListModel(refs: refs([], partial: true), checkedOut: [], remoteNames: []).warning,
            "Some branches could not be listed because git's output was too large.")
    }
}
