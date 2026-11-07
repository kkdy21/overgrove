import Foundation
import XCTest

@testable import Overgrove

/// ADR-0019 (#106, T10): when a git chosen in Settings may run. Real files in a fresh temporary directory, plus an
/// injected file-status lookup for owners a test cannot create.
final class GitExecutablePolicyTests: XCTestCase {
    private var executables: TestExecutables!

    override func setUpWithError() throws {
        executables = try TestExecutables()
    }

    override func tearDown() {
        executables.remove()
    }

    /// A fake git in its own directory, mode 0755, under the test's own temporary directory.
    private func makeGit() throws -> URL {
        try executables.fakeDeveloperDirectory(versionLine: "git version 2.45.1")
            .appendingPathComponent("usr/bin/git")
    }

    /// `realpath` (Foundation's `resolvingSymlinksInPath` drops `/private`, which the policy keeps).
    private func resolved(_ url: URL) -> String {
        guard let real = realpath(url.path, nil) else { return url.path }
        defer { free(real) }
        return String(cString: real)
    }

    // MARK: - Path

    func testAnAcceptableGitIsAcceptedWithItsRealPath() throws {
        let git = try makeGit()
        let link = executables.directory.appendingPathComponent("git-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: git)

        let outcome = try GitExecutablePolicy.check(path: link.path, protectedDirectories: [])
        XCTAssertEqual(outcome, .chosen(entered: link.path, resolved: URL(fileURLWithPath: resolved(git))))
        XCTAssertFalse(GitExecutablePolicy.isAppleSigned(URL(fileURLWithPath: resolved(git))), "a shell script")
    }

    func testRelativeMissingAndNonExecutablePathsAreRefused() throws {
        XCTAssertThrowsError(try GitExecutablePolicy.check(path: "bin/git", protectedDirectories: [])) {
            XCTAssertEqual($0 as? GitExecutablePolicy.Rejection, .notAbsolute)
        }
        let missing = executables.directory.appendingPathComponent("missing").path
        XCTAssertThrowsError(try GitExecutablePolicy.check(path: missing, protectedDirectories: [])) {
            XCTAssertEqual($0 as? GitExecutablePolicy.Rejection, .notFound)
        }
        XCTAssertThrowsError(
            try GitExecutablePolicy.check(path: executables.directory.path, protectedDirectories: [])
        ) {
            XCTAssertEqual($0 as? GitExecutablePolicy.Rejection, .notAFile)
        }
        let plain = executables.directory.appendingPathComponent("plain")
        try Data("not a program\n".utf8).write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        XCTAssertThrowsError(try GitExecutablePolicy.check(path: plain.path, protectedDirectories: [])) {
            XCTAssertEqual($0 as? GitExecutablePolicy.Rejection, .notExecutable)
        }
    }

    /// The `/usr/bin/git` shim stands for the default git (ADR-0008: ~8 ms per call and the install dialog).
    func testTheXcrunShimMeansTheDefault() throws {
        XCTAssertEqual(try GitExecutablePolicy.check(path: "/usr/bin/git", protectedDirectories: []), .useDefault)
    }

    /// SEC-T10-04: a git inside a registered repository, its git directory, or a worktree is refused, whether the
    /// entered path or the path it resolves to is inside (a lure to "use the git in this repository").
    func testSECT10_04_AGitInsideARegisteredRepositoryIsRefused() throws {
        let repository = executables.directory.appendingPathComponent("repo", isDirectory: true)
        let inside = repository.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let git = inside.appendingPathComponent("git")
        try FileManager.default.copyItem(at: try makeGit(), to: git)

        XCTAssertThrowsError(try GitExecutablePolicy.check(path: git.path, protectedDirectories: [repository])) {
            XCTAssertEqual($0 as? GitExecutablePolicy.Rejection, .insideRepository)
        }
        // A link outside that resolves inside.
        let link = executables.directory.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: git)
        XCTAssertThrowsError(try GitExecutablePolicy.check(path: link.path, protectedDirectories: [repository])) {
            XCTAssertEqual($0 as? GitExecutablePolicy.Rejection, .insideRepository)
        }
        // A link inside that resolves outside.
        let outside = try makeGit()
        let linkInside = inside.appendingPathComponent("git-out")
        try FileManager.default.createSymbolicLink(at: linkInside, withDestinationURL: outside)
        XCTAssertThrowsError(
            try GitExecutablePolicy.check(path: linkInside.path, protectedDirectories: [repository])
        ) {
            XCTAssertEqual($0 as? GitExecutablePolicy.Rejection, .insideRepository)
        }
        // A sibling whose name only starts with the repository's name is not inside it.
        let sibling = executables.directory.appendingPathComponent("repo-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let siblingGit = sibling.appendingPathComponent("git")
        try FileManager.default.copyItem(at: try makeGit(), to: siblingGit)
        XCTAssertNoThrow(try GitExecutablePolicy.check(path: siblingGit.path, protectedDirectories: [repository]))
    }

    // MARK: - Ownership and permissions

    /// SEC-T10-05: the real file and every directory above it, on the entered path too, must be owned by root or the
    /// user and not writable by group or others.
    func testSECT10_05_WritableByOthersIsRefused() throws {
        let git = try makeGit()
        let directory = git.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try GitExecutablePolicy.check(path: git.path, protectedDirectories: [])) {
            XCTAssertEqual($0 as? GitExecutablePolicy.Rejection, .writableByOthers(self.resolved(directory)))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o757], ofItemAtPath: git.path)
        XCTAssertThrowsError(try GitExecutablePolicy.check(path: git.path, protectedDirectories: [])) {
            XCTAssertEqual($0 as? GitExecutablePolicy.Rejection, .writableByOthers(self.resolved(git)))
        }
    }

    /// SEC-T10-05: a link in a directory others may write could be swapped, so the entered path's directories count.
    func testSECT10_05_ALinkInAWritableDirectoryIsRefused() throws {
        let git = try makeGit()
        let shared = executables.directory.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let link = shared.appendingPathComponent("git")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: git)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: shared.path)
        XCTAssertThrowsError(try GitExecutablePolicy.check(path: link.path, protectedDirectories: [])) {
            XCTAssertEqual($0 as? GitExecutablePolicy.Rejection, .writableByOthers(self.resolved(shared)))
        }
    }

    /// SEC-T10-05: an owner other than root or the user is refused (injected: a test cannot create such a file).
    func testSECT10_05_AnotherOwnerIsRefused() throws {
        let git = try makeGit()
        let real = resolved(git)
        func owned(by owner: uid_t) -> (String) -> GitExecutablePolicy.FileStatus? {
            { path in
                guard var status = GitExecutablePolicy.FileStatus.current(path) else { return nil }
                if path == real { status.owner = owner }
                return status
            }
        }
        XCTAssertThrowsError(
            try GitExecutablePolicy.check(path: git.path, protectedDirectories: [], fileStatus: owned(by: 4242))
        ) {
            XCTAssertEqual($0 as? GitExecutablePolicy.Rejection, .unsafeOwner(real))
        }
        XCTAssertNoThrow(
            try GitExecutablePolicy.check(path: git.path, protectedDirectories: [], fileStatus: owned(by: 0)),
            "root is fine")
    }

    /// SEC-T10-05: group write is accepted only for `wheel` and `admin`, whose members can become root (macOS ships
    /// `/Applications` as `root:admin` 0775). Any other group, and write by others, is refused.
    func testSECT10_05_GroupWriteOnlyForAdministrativeGroups() throws {
        let git = try makeGit()
        let directory = resolved(git.deletingLastPathComponent())
        func groupWritable(group: gid_t, mode: mode_t) -> (String) -> GitExecutablePolicy.FileStatus? {
            { path in
                guard var status = GitExecutablePolicy.FileStatus.current(path) else { return nil }
                if path == directory {
                    status.group = group
                    status.mode = (status.mode & ~0o777) | mode
                }
                return status
            }
        }
        XCTAssertNoThrow(
            try GitExecutablePolicy.check(
                path: git.path, protectedDirectories: [], fileStatus: groupWritable(group: 80, mode: 0o775)), "admin")
        XCTAssertNoThrow(
            try GitExecutablePolicy.check(
                path: git.path, protectedDirectories: [], fileStatus: groupWritable(group: 0, mode: 0o775)), "wheel")
        XCTAssertThrowsError(
            try GitExecutablePolicy.check(
                path: git.path, protectedDirectories: [], fileStatus: groupWritable(group: 20, mode: 0o775))
        ) {
            XCTAssertEqual($0 as? GitExecutablePolicy.Rejection, .writableByOthers(directory), "staff")
        }
        XCTAssertThrowsError(
            try GitExecutablePolicy.check(
                path: git.path, protectedDirectories: [], fileStatus: groupWritable(group: 80, mode: 0o757))
        ) {
            XCTAssertEqual($0 as? GitExecutablePolicy.Rejection, .writableByOthers(directory), "others")
        }
    }

    /// Shared sticky directories such as `/tmp` are writable by others, so a git there is refused.
    func testAGitInTmpIsRefused() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("overgrove-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let git = directory.appendingPathComponent("git")
        try FileManager.default.copyItem(at: try makeGit(), to: git)
        XCTAssertThrowsError(try GitExecutablePolicy.check(path: git.path, protectedDirectories: [])) {
            guard case .writableByOthers = $0 as? GitExecutablePolicy.Rejection else { return XCTFail("got \($0)") }
        }
    }

    /// Real installs on this Mac pass: the developer directory's git (Apple-signed) and Homebrew git when present.
    func testInstalledGitsPass() async throws {
        let app = try await GitEnvironment.discover()
        let real = URL(fileURLWithPath: resolved(app.executable))
        let outcome = try GitExecutablePolicy.check(path: app.executable.path, protectedDirectories: [])
        XCTAssertEqual(outcome, .chosen(entered: app.executable.path, resolved: real))
        XCTAssertTrue(GitExecutablePolicy.isAppleSigned(real))

        let homebrew = "/opt/homebrew/bin/git"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: homebrew), "no Homebrew git")
        guard case .chosen(_, let brewReal) = try GitExecutablePolicy.check(path: homebrew, protectedDirectories: [])
        else { return XCTFail("Homebrew git is a real file, not the shim") }
        XCTAssertFalse(GitExecutablePolicy.isAppleSigned(brewReal))
    }
}

/// ADR-0019 §4 (#106): every discovery re-checks the chosen git and fails closed.
final class GitExecutableResolveTests: XCTestCase {
    private var executables: TestExecutables!

    override func setUpWithError() throws {
        executables = try TestExecutables()
    }

    override func tearDown() {
        executables.remove()
    }

    /// Records whether the default git was looked up.
    private final class DefaultLookup: @unchecked Sendable {
        var used = false
    }

    private func resolve(_ path: String?, protected: [URL] = [], lookup: DefaultLookup) async throws -> GitEnvironment {
        let fallback = try executables.fakeDeveloperDirectory(versionLine: "git version 2.54.0")
        return try await GitEnvironment.resolve(
            chosenPath: path, protectedDirectories: protected,
            developerDirectory: {
                lookup.used = true
                return fallback
            })
    }

    func testNoChoiceUsesTheDefault() async throws {
        let lookup = DefaultLookup()
        let environment = try await resolve(nil, lookup: lookup)
        XCTAssertTrue(lookup.used)
        XCTAssertEqual(environment.version, GitVersion(major: 2, minor: 54, patch: 0))
        let empty = DefaultLookup()
        _ = try await resolve("", lookup: empty)
        XCTAssertTrue(empty.used)
    }

    func testAnAcceptedChoiceRunsItsRealFile() async throws {
        let git = try executables.fakeDeveloperDirectory(versionLine: "git version 2.45.1")
            .appendingPathComponent("usr/bin/git")
        let lookup = DefaultLookup()
        let environment = try await resolve(git.path, lookup: lookup)
        XCTAssertFalse(lookup.used, "the default git is not looked up")
        XCTAssertEqual(environment.version, GitVersion(major: 2, minor: 45, patch: 1))
        XCTAssertEqual(environment.executable.lastPathComponent, "git")
        XCTAssertTrue(environment.executable.path.hasPrefix("/private/"), "the real path, links resolved")
    }

    /// SEC-T10-06: a stored choice that no longer passes stops discovery with the reason. The default git is not used
    /// in its place (ADR-0019 §4).
    func testSECT10_06_ARejectedChoiceFailsClosed() async throws {
        let git = try executables.fakeDeveloperDirectory(versionLine: "git version 2.45.1")
            .appendingPathComponent("usr/bin/git")
        try FileManager.default.setAttributes([.posixPermissions: 0o757], ofItemAtPath: git.path)
        for path in [git.path, "relative/git", executables.directory.appendingPathComponent("gone").path] {
            let lookup = DefaultLookup()
            do {
                _ = try await resolve(path, lookup: lookup)
                XCTFail("\(path): expected a rejection")
            } catch let error as GitError {
                guard case .chosenExecutableRejected(let shown, let reason) = error else {
                    return XCTFail("\(path): got \(error)")
                }
                XCTAssertEqual(shown, PathValidator.displayable(path))
                XCTAssertFalse(reason.isEmpty)
                XCTAssertTrue(error.message.contains("Settings"), error.message)
            }
            XCTAssertFalse(lookup.used, "\(path): no fallback to the default git")
        }
    }

    /// SEC-T10-06: a choice below the minimum version is refused too, without falling back.
    func testSECT10_06_AnOldChoiceIsRefused() async throws {
        let git = try executables.fakeDeveloperDirectory(versionLine: "git version 2.30.1")
            .appendingPathComponent("usr/bin/git")
        let lookup = DefaultLookup()
        do {
            _ = try await resolve(git.path, lookup: lookup)
            XCTFail("expected unsupportedVersion")
        } catch let error as GitError {
            XCTAssertEqual(error, .unsupportedVersion(found: GitVersion(major: 2, minor: 30, patch: 1)))
        }
        XCTAssertFalse(lookup.used)
    }

    func testTheShimChoiceUsesTheDefault() async throws {
        let lookup = DefaultLookup()
        _ = try await resolve("/usr/bin/git", lookup: lookup)
        XCTAssertTrue(lookup.used)
    }

    /// The real installs on this Mac resolve when chosen: the developer directory's git and Homebrew git if present.
    func testInstalledGitsResolveWhenChosen() async throws {
        let app = try await GitEnvironment.discover()
        let chosen = try await GitEnvironment.resolve(chosenPath: app.executable.path, protectedDirectories: [])
        XCTAssertEqual(chosen.version, app.version)

        let homebrew = "/opt/homebrew/bin/git"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: homebrew), "no Homebrew git")
        let brew = try await GitEnvironment.resolve(chosenPath: homebrew, protectedDirectories: [])
        XCTAssertTrue(brew.executable.path.hasPrefix("/opt/homebrew/Cellar/"), brew.executable.path)
        XCTAssertTrue(brew.version.isSupported)
    }

    /// Linked worktrees count as protected without running git: their paths come from
    /// `<common dir>/worktrees/*/gitdir`.
    func testLinkedWorktreesAreProtectedFromTheirGitdirFiles() throws {
        let common = executables.directory.appendingPathComponent("repo/.git", isDirectory: true)
        let entry = common.appendingPathComponent("worktrees/feature", isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let worktree = executables.directory.appendingPathComponent("wt-feature", isDirectory: true)
        try "\(worktree.path)/.git\n".write(
            to: entry.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
        let registered = RegisteredRepository(
            rootPath: executables.directory.appendingPathComponent("repo").path, commonDirectoryPath: common.path)

        let protected = GitExecutablePolicy.protectedDirectories(for: [registered]).map(\.path)
        XCTAssertEqual(Set(protected), [registered.rootPath!, common.path, worktree.path])
    }
}
