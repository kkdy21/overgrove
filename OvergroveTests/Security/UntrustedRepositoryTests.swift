import Foundation
import XCTest

@testable import Overgrove

/// The per-repository untrusted mode (#107, ADR-0009, T5): a repository marked untrusted never fetches a remote on
/// this Mac (a local path or `file://`), because that runs `git-upload-pack` in the other repository with its own,
/// unchecked settings. Network remotes still fetch: their upload-pack runs on the server.
final class UntrustedRepositoryTests: XCTestCase {
    // MARK: - Stored flag

    @MainActor
    func testTheFlagIsStoredAndOldEntriesReadAsTrusted() throws {
        let suite = "overgrove-untrusted-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Saved before #107: no flag.
        let old = #"[{"rootPath":"/tmp/dev/api","commonDirectoryPath":"/tmp/dev/api/.git"}]"#
        defaults.set(Data(old.utf8), forKey: RepositoryRegistry.repositoriesKey)
        let registry = RepositoryRegistry(defaults: defaults)
        let entry = try XCTUnwrap(registry.repositories.first)
        XCTAssertFalse(entry.isUntrusted, "absent means trusted, as before")

        registry.setUntrusted(true, for: entry.id)
        XCTAssertEqual(RepositoryRegistry(defaults: defaults).repositories.first?.isUntrusted, true)
        registry.setUntrusted(false, for: entry.id)
        XCTAssertEqual(RepositoryRegistry(defaults: defaults).repositories.first?.isUntrusted, false)
    }

    /// Stored values are untrusted: a flag that is present but not a boolean reads as untrusted (the safe side), and
    /// the entry is still loaded.
    @MainActor
    func testAnUnreadableFlagReadsAsUntrusted() throws {
        let suite = "overgrove-untrusted-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let odd = #"[{"rootPath":"/tmp/dev/api","commonDirectoryPath":"/tmp/dev/api/.git","isUntrusted":"no"}]"#
        defaults.set(Data(odd.utf8), forKey: RepositoryRegistry.repositoriesKey)
        XCTAssertEqual(RepositoryRegistry(defaults: defaults).repositories.map(\.isUntrusted), [true])
    }

    /// One damaged entry drops only itself: the other entries and their untrusted flags survive.
    @MainActor
    func testADamagedEntryDoesNotDropTheOthers() throws {
        let suite = "overgrove-untrusted-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = #"""
            [{"rootPath":"/tmp/dev/api","commonDirectoryPath":"/tmp/dev/api/.git","isUntrusted":true},
             {"rootPath":42},
             {"rootPath":"/tmp/dev/web","commonDirectoryPath":"/tmp/dev/web/.git"}]
            """#
        defaults.set(Data(stored.utf8), forKey: RepositoryRegistry.repositoriesKey)
        let entries = RepositoryRegistry(defaults: defaults).repositories
        XCTAssertEqual(entries.map(\.rootPath), ["/tmp/dev/api", "/tmp/dev/web"])
        XCTAssertEqual(entries.map(\.isUntrusted), [true, false])
    }

    // MARK: - Local remotes

    /// git's own rule (`url_is_local_not_ssh`): a URL without `://` is local unless it looks like `host:path` with no
    /// slash before the colon; `file://` is local; helpers (`x::y`) and other schemes are not.
    func testLocalRemoteURLs() {
        let local = [
            "/srv/git/api.git", "../api.git", "api", "./a:b", "file:///srv/git/api.git", "FILE:///x", "/a/b:c",
        ]
        let notLocal = [
            "https://github.com/acme/api.git", "ssh://git@host/acme/api.git", "git@github.com:acme/api.git",
            "host:api.git", "git://host/api.git", "ext::sh -c x", "helper::x", "",
        ]
        for url in local { XCTAssertTrue(RemoteLocation.isLocal(url), url) }
        for url in notLocal { XCTAssertFalse(RemoteLocation.isLocal(url), url) }
    }

    // MARK: - Fetch environment

    func testFetchOfAnUntrustedRepositoryAllowsNoFileTransport() {
        let trusted = GitEnvironment.environment(parent: [:], allowsTransport: true)
        XCTAssertEqual(trusted["GIT_ALLOW_PROTOCOL"], "https:ssh:git:file:http")
        let untrusted = GitEnvironment.environment(parent: [:], allowsTransport: true, allowsLocalTransport: false)
        XCTAssertEqual(untrusted["GIT_ALLOW_PROTOCOL"], "https:ssh:git:http")
        let query = GitEnvironment.environment(parent: [:], allowsTransport: false, allowsLocalTransport: true)
        XCTAssertEqual(query["GIT_ALLOW_PROTOCOL"], "", "queries never get a transport")
    }

    /// SEC-T5-19: a fetch of an untrusted repository from a local path remote is refused by git before anything runs
    /// in the other repository (`transport 'file' not allowed`); the same fetch of a trusted repository works. The
    /// app's real `GitClient.fetch` with the real environment.
    func testSECT5_19_UntrustedFetchRefusesALocalRemote() async throws {
        let source = try await GitTestRepository.make()
        defer { source.remove() }
        try source.write("a.txt", "a\n")
        try await source.git(["add", "a.txt"])
        try await source.git(["commit", "-q", "-m", "one"])
        let local = try await GitTestRepository.make()
        defer { local.remove() }
        try await local.git(["remote", "add", "origin", source.root.path])

        let listing = try await GitClient(environment: local.environment)
            .run(.configList, in: local.root, safety: .preInspection)
        var safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)
        let repository = Repository(
            rootURL: local.root, commonGitDirectoryURL: local.root.appendingPathComponent(".git"), isBare: false)
        let client = GitClient(environment: local.environment)

        safety.blocksLocalTransport = true
        do {
            _ = try await client.fetch(.fetch(remote: RemoteName("origin")!), in: repository, safety: safety)
            XCTFail("an untrusted repository must not fetch a local remote")
        } catch let error as GitError {
            guard case .transportNotAllowed("file", _) = error else { return XCTFail("got \(error)") }
        }
        let none = try await local.git(["for-each-ref", "refs/remotes"])
        XCTAssertTrue(none.stdout.isEmpty, "nothing was fetched")

        safety.blocksLocalTransport = false
        _ = try await client.fetch(.fetch(remote: RemoteName("origin")!), in: repository, safety: safety)
        let fetched = try await local.git(["for-each-ref", "--format=%(refname)", "refs/remotes"])
        XCTAssertEqual(String(decoding: fetched.stdout, as: UTF8.self), "refs/remotes/origin/main\n")
    }
}
