import Foundation
import XCTest

@testable import Overgrove

/// T9: argument validation (SEC-T9-02, SEC-T9-04).
final class GitArgumentsTests: XCTestCase {
    func testSECT9_02_ValidRefs() {
        for ref in [
            "refs/heads/main", "refs/heads/feat/12-worktree-list", "refs/remotes/origin/main", "refs/tags/v1.0.0",
            "refs/heads/한글-브랜치", "refs/heads/a.b", "refs/heads/x@y",
        ] {
            XCTAssertNotNil(FullRefName(ref), ref)
        }
    }

    func testSECT9_02_RejectedRefs() {
        let rejected = [
            "main", "-x", "--output=x", "refs/heads/-x", "refs/heads/a..b", "refs/heads/a\nb", "refs/heads/a\u{7F}",
            "refs/heads/a b", "refs/heads/a~1", "refs/heads/a^", "refs/heads/a:b", "refs/heads/a?", "refs/heads/a*",
            "refs/heads/a[", "refs/heads/a\\b", "refs/heads/a@{1}", "refs/heads/.hidden", "refs/heads/x.lock",
            "refs/heads/x/", "refs/heads//x", "refs/heads/x.", "refs/", "HEAD", "@",
        ]
        for ref in rejected {
            XCTAssertNil(FullRefName(ref), ref.debugDescription)
        }
    }

    func testSECT9_04_ObjectIDs() {
        XCTAssertNotNil(ObjectID(String(repeating: "0123456789", count: 4)))
        XCTAssertNotNil(ObjectID(String(repeating: "abcdef01", count: 8)))
        for bad in [
            "HEAD", "main", "-n", "abc1234", String(repeating: "A", count: 40), String(repeating: "a", count: 39),
        ] {
            XCTAssertNil(ObjectID(bad), bad)
        }
    }

    func testRemoteNames() {
        for name in ["origin", "upstream", "my.fork", "team/remote", "a_b-c"] {
            XCTAssertNotNil(RemoteName(name), name)
        }
        for name in [
            "", "-origin", "--upload-pack=x", "a..b", "a b", "a;b", "ext::sh", String(repeating: "r", count: 101),
        ] {
            XCTAssertNil(RemoteName(name), name)
        }
    }

    func testPathspecArgumentsAlwaysFollowDoubleDash() {
        XCTAssertEqual(GitPath("--output=x").pathspecArguments, ["--", "--output=x"])
        XCTAssertEqual(GitPath(":(exclude)x").pathspecArguments, ["--", ":(exclude)x"])
        XCTAssertNil(GitPath(raw: Data([0x61, 0xFF])).pathspecArguments, "lossy paths are never sent back")
    }
}

/// SEC-T9-03: hostile file names reach git only as literal paths after `--`.
final class HostilePathTests: XCTestCase {
    private let hostileNames = ["-x", "--output=x", ":(exclude)x", "*"]

    func testSECT9_03_HostileFileNamesAreLiteral() async throws {
        let repository = try await GitTestRepository.make()
        defer { repository.remove() }
        for name in hostileNames + ["a.txt"] {
            try repository.write(name, "v1 \(name)\n")
        }
        try await repository.git(["add", "--all"])
        try await repository.git(["commit", "-q", "-m", "one"])
        for name in hostileNames {
            try repository.write(name, "v2 \(name)\n")
            try await repository.git(["add", "--", name])
            try await repository.git(["commit", "-q", "-m", "change \(name)"])
        }

        for name in hostileNames {
            let path = GitPath(name)
            let pathspec = try XCTUnwrap(path.pathspecArguments)
            // File history: only the commit that changed this file plus the initial one.
            let log = try await repository.git(["log", "--format=%s"] + pathspec)
            XCTAssertEqual(String(decoding: log.stdout, as: UTF8.self), "change \(name)\none\n", name)
            // Diff of the working tree after an edit: only this file.
            try repository.write(name, "v3 \(name)\n")
            let diff = try await repository.git(["diff", "--no-ext-diff", "--no-textconv", "--name-only"] + pathspec)
            XCTAssertEqual(String(decoding: diff.stdout, as: UTF8.self), "\(name)\n", name)
            try await repository.git(["checkout", "-q", "--", name])
        }
        XCTAssertFalse(repository.fileExists("x"), "--output=x must not create a file")
    }
}
