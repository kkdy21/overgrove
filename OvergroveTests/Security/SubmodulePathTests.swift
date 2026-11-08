import Foundation
import XCTest

@testable import Overgrove

/// SEC-T14-11 (file-system part, #108): submodule paths and git directories come from repository-controlled files,
/// so they are checked before git runs in a submodule.
final class SubmodulePathTests: XCTestCase {
    private var root: URL!
    private var worktree: URL!
    private var common: URL!

    override func setUpWithError() throws {
        let base = try XCTUnwrap(PathValidator.canonical(FileManager.default.temporaryDirectory))
        root = base.appendingPathComponent("overgrove-submodule-\(UUID().uuidString)", isDirectory: true)
        worktree = root.appendingPathComponent("wt", isDirectory: true)
        common = worktree.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: common.appendingPathComponent("modules/libs/a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent("libs/a"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ path: String) -> PathValidator.SubmoduleFolder {
        PathValidator.submoduleFolder(GitPath(path), in: worktree)
    }

    func testValidFolders() {
        XCTAssertEqual(folder("libs/a"), .folder(worktree.appendingPathComponent("libs/a")))
        XCTAssertEqual(folder("libs/a/"), .folder(worktree.appendingPathComponent("libs/a")), "trailing slash")
        XCTAssertEqual(folder("libs/missing"), .missing)
    }

    func testHostilePathsAreInvalid() throws {
        try "x".write(to: worktree.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        for path in ["", "/etc", "../outside", "libs/../..", "./libs/a", "libs//a", "libs/a/..", "lib\ns", "file"] {
            XCTAssertEqual(folder(path), .invalid, path)
        }
        XCTAssertEqual(PathValidator.submoduleFolder(GitPath(raw: Data([0x61, 0xFF])), in: worktree), .invalid)
    }

    func testSymbolicLinksAreNotFollowed() throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: worktree.appendingPathComponent("escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: worktree.appendingPathComponent("alias"), withDestinationURL: worktree.appendingPathComponent("libs"))
        XCTAssertEqual(folder("escape"), .symbolicLink)
        XCTAssertEqual(folder("alias/a"), .symbolicLink, "even one that stays inside the worktree")
    }

    private func gitDirectory(of path: String) -> PathValidator.SubmoduleGitDirectory {
        PathValidator.submoduleGitDirectory(
            of: worktree.appendingPathComponent(path), commonDirectory: common, worktreeGitDirectory: common)
    }

    private func writeGitFile(_ target: String, in path: String) throws {
        try "gitdir: \(target)\n".write(
            to: worktree.appendingPathComponent(path).appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    }

    func testGitDirectoryUnderModules() throws {
        try writeGitFile("../../.git/modules/libs/a", in: "libs/a")
        let expected = try XCTUnwrap(PathValidator.canonical(common.appendingPathComponent("modules/libs/a")))
        XCTAssertEqual(gitDirectory(of: "libs/a"), .inside(expected))
    }

    func testGitDirectoryElsewhereIsOutside() throws {
        let other = root.appendingPathComponent("other.git", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try writeGitFile(other.path, in: "libs/a")
        XCTAssertEqual(gitDirectory(of: "libs/a"), .outside, "another repository on disk")
        try writeGitFile("../../.git/modules", in: "libs/a")
        XCTAssertEqual(gitDirectory(of: "libs/a"), .outside, "modules itself")
        try writeGitFile("../../.git", in: "libs/a")
        XCTAssertEqual(gitDirectory(of: "libs/a"), .outside, "the superproject's own git directory")
        // The target exists, so this checks dot-segment resolution, not a missing directory (#430).
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent("outside", isDirectory: true), withIntermediateDirectories: true)
        try writeGitFile("../../.git/modules/../../outside", in: "libs/a")
        XCTAssertEqual(gitDirectory(of: "libs/a"), .outside, "dot segments resolved")
    }

    /// #430: a `.git` file whose git directory does not exist (an interrupted `submodule update`, a partial copy) is
    /// a broken checkout, not another repository. Nothing runs there either way. A malformed `.git` file stays
    /// `.outside`.
    func testMissingGitDirectoryIsNotOutside() throws {
        try writeGitFile("../../.git/modules/libs/gone", in: "libs/a")
        XCTAssertEqual(gitDirectory(of: "libs/a"), .gitDirectoryMissing)
        try writeGitFile(root.appendingPathComponent("nowhere/x.git").path, in: "libs/a")
        XCTAssertEqual(gitDirectory(of: "libs/a"), .gitDirectoryMissing, "missing wherever it points")
        try "not a gitdir line\n".write(
            to: worktree.appendingPathComponent("libs/a/.git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(gitDirectory(of: "libs/a"), .outside, "malformed")
    }

    func testGitEntryKinds() throws {
        XCTAssertEqual(gitDirectory(of: "libs/a"), .notCheckedOut)
        let own = worktree.appendingPathComponent("libs/a/.git", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        XCTAssertEqual(gitDirectory(of: "libs/a"), .inside(try XCTUnwrap(PathValidator.canonical(own))))
        try FileManager.default.removeItem(at: own)
        try FileManager.default.createSymbolicLink(
            at: own, withDestinationURL: common.appendingPathComponent("modules/libs/a"))
        XCTAssertEqual(gitDirectory(of: "libs/a"), .outside, "a symbolic link .git is not followed")
    }
}
