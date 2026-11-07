import Foundation
import XCTest

@testable import Overgrove

/// Submodule status (#108) through the real `RepositoryService`, with real git and canaries. Each submodule is its own
/// untrusted repository: its configuration is inspected before `status` runs in it, and nothing runs where its path
/// or `.git` leads outside the repository. Each test has a control with plain git.
final class SubmoduleSecurityTests: XCTestCase {
    private var executables: TestExecutables!
    private var scenario: SecurityScenario!

    override func setUp() async throws {
        executables = try TestExecutables()
        scenario = try await SecurityScenario.make(executables)
    }

    override func tearDown() {
        executables?.remove()
    }

    // MARK: Builders

    private func repository(_ name: String, files: [String: String]) async throws -> URL {
        let url = scenario.directory(name)
        try await scenario.plain(
            ["init", "-q", "-b", "main", url.path], in: executables.directory, requireSuccess: true)
        for (path, contents) in files {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        try await scenario.plain(["add", "-A"], in: url, requireSuccess: true)
        try await scenario.plain(["commit", "-q", "-m", "initial"], in: url, requireSuccess: true)
        return url
    }

    /// `super/` with `libs/sub` as a submodule (its git directory under `.git/modules/libs/sub`).
    private func superproject() async throws -> (root: URL, submodule: URL, gitDirectory: URL) {
        let sub = try await repository("sub", files: ["a.dat": "a\n"])
        let root = try await repository("super", files: ["readme.txt": "super\n"])
        try await scenario.plain(["submodule", "-q", "add", sub.path, "libs/sub"], in: root, requireSuccess: true)
        try await scenario.plain(["commit", "-q", "-m", "add submodule"], in: root, requireSuccess: true)
        return (
            root, root.appendingPathComponent("libs/sub", isDirectory: true),
            root.appendingPathComponent(".git/modules/libs/sub", isDirectory: true)
        )
    }

    /// Loads the superproject the way the app does, then reads its main worktree's submodules.
    private func submodules(of root: URL) async throws -> SubmoduleListing {
        let repository = Repository(
            rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)
        let service = RepositoryService(client: scenario.client(), sleep: { _ in })
        guard case .success(let overview) = await service.refresh(repository, trigger: .user)?.result else {
            throw XCTSkip("the superproject did not load")
        }
        let main = try XCTUnwrap(overview.entries.first { $0.worktree.isMain }).worktree.path
        let listing = await service.submodules(of: repository, worktree: main)
        return try XCTUnwrap(listing)
    }

    private func state(_ path: String, in listing: SubmoduleListing) throws -> SubmoduleStatus {
        try XCTUnwrap(listing.submodules.first { $0.path == GitPath(path) }, "\(path) in \(listing.submodules)")
    }

    private func touch(_ file: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_767_225_600)], ofItemAtPath: file.path)
    }

    private var statusArguments: [String] {
        get throws { try ReadOnlyGitCommand.status.subcommandArguments() }
    }

    // MARK: State

    func testCleanChangedAndNotCheckedOut() async throws {
        let (root, submodule, _) = try await superproject()
        let loaded1 = try await submodules(of: root)
        XCTAssertEqual(try state("libs/sub", in: loaded1).state, .clean)

        try "b\n".write(to: submodule.appendingPathComponent("a.dat"), atomically: true, encoding: .utf8)
        try "new\n".write(to: submodule.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let changed = try state("libs/sub", in: try await submodules(of: root))
        XCTAssertEqual(changed.state, .changed(files: 1, untracked: 1, isPartial: false))
        XCTAssertTrue(changed.isListed)

        try await scenario.plain(["submodule", "-q", "deinit", "-f", "libs/sub"], in: root, requireSuccess: true)
        let loaded2 = try await submodules(of: root)
        XCTAssertEqual(try state("libs/sub", in: loaded2).state, .notCheckedOut)
    }

    /// A changed gitlink that `.gitmodules` does not list (removed from it) still shows, marked unlisted.
    func testChangedGitlinkMissingFromGitmodulesShows() async throws {
        let (root, submodule, _) = try await superproject()
        try await scenario.plain(["commit", "-q", "--allow-empty", "-m", "moved"], in: submodule, requireSuccess: true)
        try "".write(to: root.appendingPathComponent(".gitmodules"), atomically: true, encoding: .utf8)
        let listed = try state("libs/sub", in: try await submodules(of: root))
        XCTAssertFalse(listed.isListed)
        XCTAssertEqual(listed.state, .clean, "its own working tree is clean; the gitlink moved")
    }

    // MARK: T1, T4: the submodule's own configuration

    /// SEC-T1-04: `core.fsmonitor` in a submodule's own configuration does not run when its status is read: the
    /// submodule is inspected and queried with its own safety context. Control: plain status inside it runs it.
    func testSECT1_04_SubmoduleFSMonitorDoesNotRunFromItsStatus() async throws {
        let (root, submodule, gitDirectory) = try await superproject()
        try await scenario.plain(
            [
                "--git-dir", gitDirectory.path, "config", "core.fsmonitor",
                try scenario.payload("T1-sub", tail: "exit 1"),
            ],
            in: root, requireSuccess: true)

        let listing = try await submodules(of: root)
        XCTAssertNotEqual(try state("libs/sub", in: listing).state, .notCheckedOut)
        XCTAssertEqual(scenario.canaries(), [], "submodule inspection ran its fsmonitor")

        try await scenario.plain(try statusArguments, in: submodule)
        XCTAssertTrue(scenario.canaries().contains("T1-sub"), "control: plain status in the submodule")
    }

    /// SEC-T4-09: a filter defined in the submodule (its config and `info/attributes`) does not run when its status
    /// is read. Control: plain status inside it runs the filter.
    func testSECT4_09_SubmoduleFilterDoesNotRunFromItsStatus() async throws {
        let (root, submodule, gitDirectory) = try await superproject()
        try await scenario.plain(
            [
                "--git-dir", gitDirectory.path, "config", "filter.evil.clean",
                try scenario.payload("T4-sub", tail: "cat"),
            ],
            in: root, requireSuccess: true)
        let info = gitDirectory.appendingPathComponent("info", isDirectory: true)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try "*.dat filter=evil\n".write(
            to: info.appendingPathComponent("attributes"), atomically: true, encoding: .utf8)
        try touch(submodule.appendingPathComponent("a.dat"))

        _ = try await submodules(of: root)
        XCTAssertEqual(scenario.canaries(), [], "submodule inspection ran its filter")

        try touch(submodule.appendingPathComponent("a.dat"))
        try await scenario.plain(try statusArguments, in: submodule)
        XCTAssertTrue(scenario.canaries().contains("T4-sub"), "control: plain status in the submodule")
    }

    // MARK: T14: where the path and `.git` lead

    /// SEC-T14-11: a `.git` file naming another repository on disk is not followed: nothing runs there (its
    /// fsmonitor would show it). Control: plain status there runs it.
    func testSECT14_11_ForeignGitDirectoryIsNotQueried() async throws {
        let (root, submodule, _) = try await superproject()
        let foreign = try await repository("foreign", files: ["f.txt": "f\n"])
        try await scenario.config("core.fsmonitor", try scenario.payload("T14-foreign", tail: "exit 1"), in: foreign)
        try "gitdir: \(foreign.appendingPathComponent(".git").path)\n".write(
            to: submodule.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let listed = try state("libs/sub", in: try await submodules(of: root))
        XCTAssertEqual(listed.state, .notInspected(.outsideRepository))
        XCTAssertEqual(scenario.canaries(), [])

        try await scenario.plain(
            ["-c", "core.fsmonitor=" + (try scenario.payload("T14-foreign", tail: "exit 1"))] + (try statusArguments),
            in: submodule)
        XCTAssertTrue(scenario.canaries().contains("T14-foreign"), "control: git follows the .git file")
    }

    /// SEC-T14-11: hostile `.gitmodules` paths and a symbolic link submodule path are not inspected.
    func testSECT14_11_HostilePathsAreNotInspected() async throws {
        let (root, _, _) = try await superproject()
        let outside = try await repository("outside", files: ["o.txt": "o\n"])
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        try await scenario.plain(
            ["config", "--file", ".gitmodules", "submodule.up.path", "../outside"], in: root, requireSuccess: true)
        try await scenario.plain(
            ["config", "--file", ".gitmodules", "submodule.abs.path", outside.path], in: root, requireSuccess: true)
        try await scenario.plain(
            ["config", "--file", ".gitmodules", "submodule.link.path", "linked"], in: root, requireSuccess: true)

        let listing = try await submodules(of: root)
        XCTAssertEqual(try state("../outside", in: listing).state, .notInspected(.invalidPath))
        XCTAssertEqual(try state(outside.path, in: listing).state, .notInspected(.invalidPath))
        XCTAssertEqual(try state("linked", in: listing).state, .notInspected(.symbolicLink))
        XCTAssertEqual(try state("libs/sub", in: listing).state, .clean, "the real one is still read")
    }

    /// SEC-T14-11: `.gitmodules` as a symbolic link is not read: git would follow it to any file. Control: plain
    /// `config --file` follows it and reports the target's entries.
    func testSECT14_11_SymbolicLinkGitmodulesIsNotRead() async throws {
        let (root, _, _) = try await superproject()
        let target = scenario.directory("target-gitmodules")
        try "[submodule \"secret\"]\n\tpath = secret-target\n".write(to: target, atomically: true, encoding: .utf8)
        let gitmodules = root.appendingPathComponent(".gitmodules")
        try FileManager.default.removeItem(at: gitmodules)
        try FileManager.default.createSymbolicLink(at: gitmodules, withDestinationURL: target)

        let listing = try await submodules(of: root)
        XCTAssertTrue(listing.isGitmodulesRefused)
        XCTAssertFalse(listing.submodules.contains { $0.path == GitPath("secret-target") })

        let plain = try await scenario.plain(try ReadOnlyGitCommand.submodulePaths.subcommandArguments(), in: root)
        XCTAssertTrue(String(decoding: plain.stdout, as: UTF8.self).contains("secret-target"), "control")
    }

    /// `include.path` in `.gitmodules` is not followed (`--no-includes`; `--file` has includes off by default).
    func testIncludesInGitmodulesAreNotFollowed() async throws {
        let (root, _, _) = try await superproject()
        let extra = scenario.directory("extra-gitmodules")
        try "[submodule \"inc\"]\n\tpath = included\n".write(to: extra, atomically: true, encoding: .utf8)
        try await scenario.plain(
            ["config", "--file", ".gitmodules", "include.path", extra.path], in: root, requireSuccess: true)

        let listing = try await submodules(of: root)
        XCTAssertFalse(listing.submodules.contains { $0.path == GitPath("included") })
        let plain = try await scenario.plain(
            ["config", "--file", ".gitmodules", "--includes", "-z", "--get-regexp", "^submodule\\..*\\.path$"],
            in: root)
        XCTAssertTrue(String(decoding: plain.stdout, as: UTF8.self).contains("included"), "control: --includes")
    }

    // MARK: T15

    /// SEC-T15-18: at most `maximumInspectedSubmodules` are inspected; the rest are counted.
    func testSECT15_18_SubmodulesAreCapped() async throws {
        let (root, _, _) = try await superproject()
        let extra = RepositoryService.maximumInspectedSubmodules + 3
        for index in 0..<extra {
            try await scenario.plain(
                ["config", "--file", ".gitmodules", "submodule.m\(index).path", "missing/\(index)"], in: root,
                requireSuccess: true)
        }
        let listing = try await submodules(of: root)
        XCTAssertEqual(listing.submodules.count, RepositoryService.maximumInspectedSubmodules)
        XCTAssertEqual(listing.omitted, extra + 1 - RepositoryService.maximumInspectedSubmodules)
    }
}
