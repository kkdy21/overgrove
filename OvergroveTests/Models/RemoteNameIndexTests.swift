import XCTest

@testable import Overgrove

/// Which remote a `refs/remotes/` ref belongs to (#466, #489).
final class RemoteNameIndexTests: XCTestCase {
    func testTheLongestNameFollowedBySlashWins() {
        let index = RemoteNameIndex(["origin", "team", "team/a", "gh/fork+1", "gh"])
        XCTAssertEqual(index.remote(of: "origin/main"), "origin")
        XCTAssertEqual(index.remote(of: "team/a/x"), "team/a")
        XCTAssertEqual(index.remote(of: "team/ab/x"), "team")
        XCTAssertEqual(index.remote(of: "gh/fork+1/topic"), "gh/fork+1")
        XCTAssertEqual(index.remote(of: "gh/main"), "gh")
        XCTAssertNil(index.remote(of: "origin"), "no branch after the name")
        XCTAssertNil(index.remote(of: "originx/main"))
        XCTAssertNil(index.remote(of: "other/main"))
        XCTAssertNil(RemoteNameIndex([""]).remote(of: "/x"))
        XCTAssertNil(RemoteNameIndex.empty.remote(of: "origin/main"))
    }

    /// Bytes, not `String` equality: a remote spelled in NFD is a different remote from one in NFC.
    func testNamesCompareInBytes() {
        let nfc = "gh/caf\u{E9}"
        let nfd = "gh/cafe\u{301}"
        func bytes(_ names: [String], _ rest: String) -> [UInt8]? {
            RemoteNameIndex(names).remote(of: rest).map { Array($0.utf8) }
        }
        XCTAssertEqual(bytes(["gh", nfc], "\(nfd)/x"), Array("gh".utf8))
        XCTAssertEqual(bytes(["gh", nfc, nfd], "\(nfd)/x"), Array(nfd.utf8))
        XCTAssertEqual(bytes(["gh", nfd, nfc], "\(nfc)/x"), Array(nfc.utf8))
    }

    /// SEC-T15-489-1: a repository chooses its remote names. 1,000 names of 1,000 bytes sharing one long prefix, against
    /// 20,000 refs under that prefix, are matched by walking each ref once, not by comparing it with every name.
    func testSECT15_489_1_LongNamesAndManyRefsStayLinear() {
        let stem = String(repeating: "a/", count: 450)
        let names = (0..<1_000).map { "\(stem)\($0)" + String(repeating: "b", count: 90) }
        let refs = (0..<20_000).map { "\(stem)\($0 % 1_000)" + String(repeating: "b", count: 90) + "/topic" }
        let clock = ContinuousClock()
        let started = clock.now
        let index = RemoteNameIndex(names)
        let matched = refs.filter { index.remote(of: $0) != nil }.count
        let elapsed = clock.now - started
        XCTAssertEqual(matched, refs.count)
        // About 1 s in a local Debug build; a scan of every name per ref compares tens of gigabytes.
        XCTAssertLessThan(elapsed, .seconds(20), "took \(elapsed)")
    }

    /// SEC-T15-489-1 (sidebar): the same holds through `BranchListModel` with every remote on GitHub. 1,000 remotes of
    /// 100 bytes sharing 95, and 20,000 remote-tracking rows: each row finds its remote and repository without
    /// scanning the remotes.
    func testSECT15_489_1_ManyGitHubRemotesAndRowsStayLinear() throws {
        let repository = try XCTUnwrap(GitHubRepository(owner: "team", name: "app"))
        let stem = String(repeating: "r", count: 95)
        let names = (0..<1_000).map { stem + String(format: "%05d", $0) }
        let oid = try XCTUnwrap(ObjectID(String(repeating: "ab", count: 20)))
        let branches = (0..<20_000).map {
            Branch(
                fullName: "refs/remotes/\(names[$0 % 1_000])/topic\($0)", kind: .remote(remote: names[$0 % 1_000]),
                target: oid, upstreamStatus: .none, isHead: false, committerDate: nil, symbolicTarget: nil)
        }
        let clock = ContinuousClock()
        let started = clock.now
        let model = BranchListModel(
            refs: RefParser.Listing(branches: branches, tags: [], isPartial: false, skippedRecords: 0), checkedOut: [],
            remoteNames: names, githubRemotes: Dictionary(uniqueKeysWithValues: names.map { ($0, repository) }))
        let elapsed = clock.now - started
        XCTAssertEqual(model.remoteCount, 20_000)
        // A scan of every GitHub remote per row took 48 s in a Debug build; this is well under a second.
        XCTAssertLessThan(elapsed, .seconds(20), "took \(elapsed)")
    }
}
