import Foundation
import XCTest

@testable import Overgrove

/// T14: file-system scope (docs/design/security-review.md).
final class PathValidatorTests: XCTestCase {
    private var sandbox: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        sandbox = fileManager.temporaryDirectory.appendingPathComponent("overgrove-paths-\(UUID().uuidString)")
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: sandbox)
    }

    private func directory(_ path: String) throws -> URL {
        let url = sandbox.appendingPathComponent(path, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ path: String, _ contents: String = "x") throws -> URL {
        let url = sandbox.appendingPathComponent(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func link(_ path: String, to destination: String) throws -> URL {
        let url = sandbox.appendingPathComponent(path)
        try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url
    }

    // MARK: Registration

    func testSECT14_01_RegistrationThroughSymlinkIsFlagged() throws {
        let real = try directory("real/repo")
        let alias = try link("alias", to: real.path)
        let check = try PathValidator.checkRegistration(alias)
        XCTAssertTrue(check.isThroughSymlink)
        XCTAssertEqual(check.resolved, PathValidator.canonical(real))
    }

    func testRegistrationOfARealDirectoryIsNotFlagged() throws {
        let real = try XCTUnwrap(PathValidator.canonical(try directory("plain")))
        XCTAssertFalse(try PathValidator.checkRegistration(real).isThroughSymlink)
    }

    func testRegistrationRejectsMissingFilesAndNonDirectories() throws {
        XCTAssertThrowsError(try PathValidator.checkRegistration(sandbox.appendingPathComponent("nope"))) {
            XCTAssertEqual($0 as? PathValidator.Failure, .doesNotExist)
        }
        XCTAssertThrowsError(try PathValidator.checkRegistration(try file("a.txt"))) {
            XCTAssertEqual($0 as? PathValidator.Failure, .notADirectory)
        }
        XCTAssertThrowsError(try PathValidator.checkRegistration(try XCTUnwrap(URL(string: "relative/path")))) {
            XCTAssertEqual($0 as? PathValidator.Failure, .notAbsolute)
        }
    }

    // MARK: Containment

    func testSECT14_02_SymlinkToOutsideIsRefused() throws {
        let worktree = try directory("wt")
        let secret = try file("outside/id_ed25519", "PRIVATE")
        let escape = try link("wt/innocent.txt", to: secret.path)
        guard case .outside = PathValidator.containment(of: escape, in: worktree) else {
            return XCTFail("a link to a file outside the worktree must be reported as outside")
        }
        XCTAssertEqual(PathValidator.symlinkTarget(at: escape), secret.path, "show the link text instead")
    }

    func testSECT14_02_DotDotEscapeIsRefused() throws {
        let worktree = try directory("wt")
        _ = try file("outside/secret.txt")
        let sneaky = worktree.appendingPathComponent("../outside/secret.txt")
        guard case .outside = PathValidator.containment(of: sneaky, in: worktree) else {
            return XCTFail("`..` must not escape the worktree")
        }
    }

    func testFilesAndInternalLinksInsideAreAllowed() throws {
        let worktree = try directory("wt")
        let target = try file("wt/src/main.swift")
        let internalLink = try link("wt/link.swift", to: "src/main.swift")
        let resolvedTarget = try XCTUnwrap(PathValidator.canonical(target))
        XCTAssertEqual(PathValidator.containment(of: target, in: worktree), .inside(resolved: resolvedTarget))
        guard case .inside = PathValidator.containment(of: internalLink, in: worktree) else {
            return XCTFail("a link that stays inside the worktree is fine")
        }
    }

    func testSiblingWithCommonPrefixIsOutside() throws {
        let worktree = try directory("wt")
        let sibling = try file("wt-other/file.txt")
        guard case .outside = PathValidator.containment(of: sibling, in: worktree) else {
            return XCTFail("`wt-other` must not count as inside `wt`")
        }
    }

    func testDanglingLinkIsMissing() throws {
        let worktree = try directory("wt")
        let dangling = try link("wt/dangling", to: sandbox.appendingPathComponent("gone").path)
        XCTAssertEqual(PathValidator.containment(of: dangling, in: worktree), .missing)
    }

    // MARK: Linked worktrees

    private func makeLinkedWorktree(name: String = "feature") throws -> (root: URL, common: URL) {
        let common = try directory("repo/.git")
        let admin = try directory("repo/.git/worktrees/\(name)")
        let root = try directory("worktrees/\(name)")
        try "gitdir: \(admin.path)\n".write(to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "\(root.appendingPathComponent(".git").path)\n".write(
            to: admin.appendingPathComponent("gitdir"),
            atomically: true,
            encoding: .utf8
        )
        return (root, common)
    }

    func testValidLinkedWorktree() throws {
        let (root, common) = try makeLinkedWorktree()
        XCTAssertEqual(
            PathValidator.checkLinkedWorktree(root: root, commonGitDirectory: common),
            .linked(name: "feature")
        )
    }

    func testMainWorktreeHasAGitDirectory() throws {
        let main = try directory("repo")
        _ = try directory("repo/.git")
        XCTAssertEqual(
            PathValidator.checkLinkedWorktree(root: main, commonGitDirectory: main.appendingPathComponent(".git")),
            .mainWorktree
        )
    }

    func testGitFilePointingAtAnotherRepositoryIsRejected() throws {
        let (root, common) = try makeLinkedWorktree()
        let foreign = try directory("evil/.git/worktrees/feature")
        try "gitdir: \(foreign.path)\n".write(
            to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        guard case .pointsOutsideRepository = PathValidator.checkLinkedWorktree(root: root, commonGitDirectory: common)
        else { return XCTFail("a .git file pointing at another repository must be rejected") }
    }

    func testBackPointerMismatchIsRejected() throws {
        let (root, common) = try makeLinkedWorktree()
        let admin = common.appendingPathComponent("worktrees/feature")
        try "/somewhere/else/.git\n".write(
            to: admin.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PathValidator.checkLinkedWorktree(root: root, commonGitDirectory: common), .backPointerMismatch)
    }

    func testMissingOrMalformedGitFile() throws {
        let bare = try directory("no-git")
        XCTAssertEqual(PathValidator.checkLinkedWorktree(root: bare, commonGitDirectory: sandbox), .missingGitFile)
        let odd = try directory("odd")
        try "not a gitdir line".write(to: odd.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PathValidator.checkLinkedWorktree(root: odd, commonGitDirectory: sandbox), .malformedGitFile)
    }
}
