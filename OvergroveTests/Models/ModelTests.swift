import Foundation
import XCTest

@testable import Overgrove

final class GitPathTests: XCTestCase {
    func testValidUTF8IsRepresentable() {
        let path = GitPath("src/naïve file.swift")
        XCTAssertTrue(path.isRepresentable)
        XCTAssertEqual(path.display, "src/naïve file.swift")
        XCTAssertEqual(path.argument, "src/naïve file.swift")
    }

    func testInvalidUTF8IsDisplayedLossilyButNotRepresentable() {
        let raw = Data([0x61, 0xFF, 0x62])  // "a<invalid>b"
        let path = GitPath(raw: raw)
        XCTAssertFalse(path.isRepresentable)
        XCTAssertEqual(path.display, "a\u{FFFD}b")
        XCTAssertNil(path.argument, "lossy paths must never be sent back to git")
        XCTAssertEqual(path.raw, raw)
    }

    func testNoUnicodeNormalization() {
        let nfc = GitPath("caf\u{E9}")
        let nfd = GitPath("cafe\u{301}")
        XCTAssertNotEqual(nfc, nfd, "NFC and NFD spellings are different paths to git")
        XCTAssertNotEqual(nfc.raw, nfd.raw)
    }
}

final class ObjectIDTests: XCTestCase {
    func testAcceptsSHA1AndSHA256() throws {
        let sha1 = try XCTUnwrap(ObjectID(String(repeating: "a1", count: 20)))
        XCTAssertFalse(sha1.isSHA256)
        XCTAssertEqual(sha1.short, "a1a1a1a")
        let sha256 = try XCTUnwrap(ObjectID(String(repeating: "0f", count: 32)))
        XCTAssertTrue(sha256.isSHA256)
    }

    func testRejectsMalformedIDs() {
        XCTAssertNil(ObjectID(""))
        XCTAssertNil(ObjectID("abc123"), "abbreviated IDs are not object IDs")
        XCTAssertNil(ObjectID(String(repeating: "A", count: 40)), "uppercase is not git's format")
        XCTAssertNil(ObjectID(String(repeating: "g", count: 40)))
        XCTAssertNil(ObjectID(String(repeating: "a", count: 41)))
        XCTAssertNil(ObjectID("-" + String(repeating: "a", count: 39)), "must not look like an option")
    }
}

final class ModelBehaviorTests: XCTestCase {
    private let oid = ObjectID(String(repeating: "ab", count: 20))!

    func testUpstreamStatusAccessors() {
        XCTAssertEqual(UpstreamStatus.none.ahead, 0)
        XCTAssertNil(UpstreamStatus.none.upstreamName)
        let tracking = UpstreamStatus.tracking(upstream: "origin/main", ahead: 2, behind: 1)
        XCTAssertEqual(tracking.ahead, 2)
        XCTAssertEqual(tracking.behind, 1)
        XCTAssertEqual(UpstreamStatus.gone(upstream: "origin/x").upstreamName, "origin/x")
    }

    func testConflictKindCoversAllUnmergedCodes() {
        XCTAssertEqual(Set(ConflictKind.allCases.map(\.rawValue)), ["DD", "AU", "UD", "UA", "DU", "AA", "UU"])
    }

    func testWorkingStateCountsDistinctPaths() {
        let file = GitPath("a.swift")
        let state = WorkingState(
            headCommit: oid,
            head: .branch("main"),
            upstream: .none,
            stashCount: 0,
            staged: [FileChange(path: file, status: .modified)],
            unstaged: [FileChange(path: file, status: .modified)],
            untracked: [FileChange(path: GitPath("new.txt"), status: .untracked)],
            conflicted: [],
            isPartial: false,
            skippedRecords: 0
        )
        XCTAssertFalse(state.isClean)
        XCTAssertEqual(state.changedPathCount, 2, "an MM file counts once")
    }

    func testWorktreeBranchShortNameAndLock() {
        let worktree = Worktree(
            path: GitPath("/tmp/wt"),
            head: oid,
            branch: "refs/heads/feat/12-x",
            isMain: false,
            isDetached: false,
            isBare: false,
            lock: .locked(reason: nil),
            isPrunable: false,
            prunableReason: nil
        )
        XCTAssertEqual(worktree.branchShortName, "feat/12-x")
        XCTAssertTrue(worktree.isLocked)
    }

    func testRefShortNames() {
        let local = Branch(
            fullName: "refs/heads/main", kind: .local, target: oid,
            upstreamStatus: .tracking(upstream: "refs/remotes/origin/main", ahead: 0, behind: 0), isHead: true,
            committerDate: nil, symbolicTarget: nil
        )
        let remote = Branch(
            fullName: "refs/remotes/origin/main", kind: .remote(remote: "origin"), target: oid,
            upstreamStatus: .none, isHead: false, committerDate: nil, symbolicTarget: nil
        )
        XCTAssertEqual(local.shortName, "main")
        XCTAssertEqual(local.upstream, "refs/remotes/origin/main")
        XCTAssertNil(remote.upstream)
        XCTAssertEqual(remote.shortName, "origin/main")
        let peeled = ObjectID(String(repeating: "cd", count: 20))!
        let tag = Tag(fullName: "refs/tags/v1.0", target: oid, peeledTarget: peeled, date: nil, objectType: .commit)
        XCTAssertEqual(tag.shortName, "v1.0")
        XCTAssertEqual(tag.commit, peeled)
    }

    func testConfigEntryKeyAndTrust() {
        let entry = ConfigEntry(
            scope: .local, section: "credential", subsection: "https://example.com", variable: "helper", value: ""
        )
        XCTAssertEqual(entry.key, "credential.https://example.com.helper")
        XCTAssertTrue(entry.scope.isRepositoryControlled)
        XCTAssertFalse(ConfigEntry.Scope.global.isRepositoryControlled)
        XCTAssertFalse(ConfigEntry.Scope.unknown.isRepositoryControlled)
    }

    func testCommitDetailSubjectAndFileStat() {
        let detail = CommitDetail(
            oid: oid, parents: [], authorName: "a", authorEmail: "a@example.com", authorDate: .distantPast,
            committerName: "c", committerEmail: "c@example.com", committerDate: .distantPast,
            message: "feat: subject\n\nbody\n", files: [FileStat(path: GitPath("img.png"), added: nil, deleted: nil)],
            isPartial: false
        )
        XCTAssertEqual(detail.subject, "feat: subject")
        XCTAssertTrue(detail.files[0].isBinary)
    }
}
