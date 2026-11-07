import Foundation
import XCTest

@testable import Overgrove

/// SEC-T5-20, SEC-T5-21: fetch runs only remotes in a built-in transport form (#350, security-review.md T5).
///
/// A remote that names a remote helper (`<name>::<address>`, `remote.<n>.vcs`, an unknown `<scheme>://`, or a URL that
/// `url.<base>.insteadOf` rewrites into one of those) is refused before git starts, and the common arguments
/// neutralize the related settings even if a fetch were started anyway.
///
/// The canary is a repository-local alias that records that it ran. `GIT_ALLOW_PROTOCOL` admits helper names that
/// match an allowed transport, and when git has no program by that name it falls back to the alias. The control run
/// leaves out the neutralizing arguments to prove the canary is reachable.
final class RemoteFormSecurityTests: XCTestCase {
    private var repository: GitTestRepository!
    private var canary: URL!

    private var origin: RemoteName { RemoteName("origin")! }

    override func setUp() async throws {
        repository = try await GitTestRepository.make()
        canary = FileManager.default.temporaryDirectory
            .appendingPathComponent("overgrove-remote-form-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: canary, withIntermediateDirectories: true)
    }

    override func tearDown() {
        repository?.remove()
        if let canary { try? FileManager.default.removeItem(at: canary) }
    }

    // MARK: - Forms

    func testBuiltInForms() {
        let builtIn = [
            "https://github.com/acme/api.git", "http://example.com/api.git", "ssh://git@host/acme/api.git",
            "git://host/api.git", "file:///srv/git/api.git", "git+ssh://host/api.git", "ssh+git://host/api.git",
            "git@github.com:acme/api.git", "host:api.git", "/srv/git/api.git", "../api.git", "api", "",
            "a/b::c", "/srv/x://y",
        ]
        let notBuiltIn = [
            "ssh::x", "git::x", "file::x", "https::https://example.com/x", "::x", "ab:::x", "helper::x",
            "ext::sh -c x", "fd::3", "evil://x", "SSH://host/x", "HTTPS://example.com/x", "FILE:///x",
            "ftp://example.com/x", "ftps://example.com/x",
        ]
        for url in builtIn { XCTAssertTrue(TransportName.isBuiltInFetchForm(url), url) }
        // git compares bytes: a combining mark after the separator does not hide it.
        XCTAssertFalse(TransportName.isBuiltInFetchForm("ssh::\u{301}x"))
        for url in notBuiltIn { XCTAssertFalse(TransportName.isBuiltInFetchForm(url), url) }
    }

    /// A rewrite is judged without joining base and URL; the result must equal judging the joined text.
    func testSplitFormEqualsJoinedForm() {
        let parts = [
            "", "s", "ssh", "ssh:", "ssh::", "ssh:/", "ssh://", ":", "::", ":/", "://", "/", "a+b", "+a", "1", "x",
            "SSH", "https", "evil", ".", "-", "é", "git@host:", "a b",
        ]
        for head in parts {
            for url in parts.flatMap({ first in parts.map { first + $0 } }) {
                let scanned = TransportName.ScannedBytes(url)
                for start in 0...url.utf8.count {
                    let tail = String(decoding: Array(url.utf8)[start...], as: UTF8.self)
                    XCTAssertEqual(
                        TransportName.isBuiltInFetchForm(TransportName.ScannedBytes(head), scanned, from: start),
                        TransportName.isBuiltInFetchForm(head + tail), "\(head) + \(url)[\(start)...]")
                }
            }
        }
    }

    private func inspect(_ entries: [(ConfigEntry.Scope, String, String?, String, String?)]) -> RepoConfigInspection {
        RepoConfigInspector.inspect(
            ConfigParser.Listing(
                entries: entries.map {
                    ConfigEntry(scope: $0.0, section: $0.1, subsection: $0.2, variable: $0.3, value: $0.4)
                }, isPartial: false))
    }

    private func fetchable(_ inspection: RepoConfigInspection) -> Set<String> {
        inspection.safetyContext?.fetchableRemotes ?? []
    }

    func testInspectionListsOnlyBuiltInRemotesAsFetchable() {
        let inspection = inspect([
            (.local, "remote", "origin", "url", "https://github.com/acme/api.git"),
            (.local, "remote", "helper", "url", "ssh::x"),
            (.local, "remote", "vcs", "url", "https://github.com/acme/api.git"),
            (.local, "remote", "vcs", "vcs", "ssh"),
            // vcs in any scope, even empty
            (.global, "remote", "empty-vcs", "vcs", ""),
            (.local, "remote", "empty-vcs", "url", "https://github.com/acme/api.git"),
            // every url value counts, not only the first
            (.local, "remote", "second", "url", "https://github.com/acme/api.git"),
            (.local, "remote", "second", "url", "git::x"),
            (.local, "remote", "local", "url", "/srv/git/api.git"),
        ])
        XCTAssertEqual(fetchable(inspection), ["origin", "local"])
        XCTAssertEqual(
            inspection.remotes.map(\.name.value), ["origin", "helper", "vcs", "empty-vcs", "second", "local"])
    }

    /// git rewrites a remote URL with `url.<base>.insteadOf` (any scope) before choosing the transport. Every matching
    /// rewrite is checked, not only the longest one git would pick, and an empty prefix matches every URL.
    func testInsteadOfRewritesAreChecked() {
        let rewritten = inspect([
            (.local, "remote", "origin", "url", "https://github.com/acme/api.git"),
            (.local, "url", "ssh::x", "insteadof", "https://github.com/"),
        ])
        XCTAssertEqual(fetchable(rewritten), [])

        let everything = inspect([
            (.local, "remote", "origin", "url", "https://github.com/acme/api.git"),
            (.global, "url", "git::", "insteadof", ""),
        ])
        XCTAssertEqual(fetchable(everything), [])

        let shorterIsAlsoChecked = inspect([
            (.local, "remote", "origin", "url", "https://github.com/acme/api.git"),
            (.local, "url", "https://mirror.example/acme/", "insteadof", "https://github.com/acme/"),
            (.local, "url", "file::x", "insteadof", "https://github.com/"),
        ])
        XCTAssertEqual(fetchable(shorterIsAlsoChecked), [])

        // Bytes, as git compares: a combining mark right after the prefix still matches it.
        let combining = inspect([
            (.local, "remote", "origin", "url", "https://github.com/\u{301}acme/api.git"),
            (.local, "url", "ssh::x", "insteadof", "https://github.com/"),
        ])
        XCTAssertEqual(fetchable(combining), [])

        let builtInRewrite = inspect([
            (.local, "remote", "origin", "url", "https://github.com/acme/api.git"),
            (.global, "url", "git@github.com:", "insteadof", "https://github.com/"),
            (.local, "url", "ssh::x", "insteadof", "https://gitlab.com/"),
            (.local, "url", "ssh::x", "pushinsteadof", "https://github.com/"),
        ])
        XCTAssertEqual(fetchable(builtInRewrite), ["origin"], "push rewrites and non-matching prefixes do not count")
    }

    /// Bounds (#262, T15). Past any bound fetch is refused; queries go on.
    func testCheckingIsBounded() {
        let origin: (ConfigEntry.Scope, String, String?, String, String?) =
            (.local, "remote", "origin", "url", "https://github.com/acme/api.git")
        var many = [origin]
        for index in 0...RepoConfigInspector.maximumInsteadOfRewrites {
            many.append((.local, "url", "https://mirror\(index).example/", "insteadof", "https://other\(index)/"))
        }
        let inspection = inspect(many)
        XCTAssertEqual(fetchable(inspection), [])
        XCTAssertNotNil(inspection.safetyContext, "queries still run")

        let urls = Array(repeating: origin, count: RepoConfigInspector.maximumURLsPerRemote + 1)
        XCTAssertEqual(fetchable(inspect(urls)), [])
        XCTAssertEqual(fetchable(inspect(Array(urls.dropLast()))), ["origin"])

        let remotes = (0...RepoConfigInspector.maximumCheckedRemotes).map {
            (ConfigEntry.Scope.local, "remote", "r\($0)" as String?, "url", "https://example.com/\($0).git" as String?)
        }
        let checked = inspect(remotes)
        XCTAssertEqual(checked.remotes.count, RepoConfigInspector.maximumCheckedRemotes + 1, "all listed")
        XCTAssertEqual(fetchable(checked).count, RepoConfigInspector.maximumCheckedRemotes, "the last is not checked")
        XCTAssertFalse(fetchable(checked).contains("r\(RepoConfigInspector.maximumCheckedRemotes)"))

        let long = "https://example.com/" + String(repeating: "a", count: RepoConfigInspector.maximumCheckedLength)
        XCTAssertEqual(fetchable(inspect([(.local, "remote", "origin", "url", long)])), [])
        let longRewrite = inspect([origin, (.global, "url", long, "insteadof", "https://elsewhere/")])
        XCTAssertEqual(fetchable(longRewrite), [], "an unchecked rewrite refuses every remote")
    }

    /// An empty URL value clears the remote's URL list on newer git, which then reads legacy remote files the
    /// inspection does not see.
    func testAnEmptyURLIsRefused() {
        XCTAssertEqual(
            fetchable(
                inspect([
                    (.local, "remote", "origin", "url", "https://github.com/acme/api.git"),
                    (.local, "remote", "origin", "url", ""),
                ])), [])
        XCTAssertEqual(fetchable(inspect([(.local, "remote", "origin", "url", nil)])), [])
    }

    /// git compares the raw bytes; the listing decodes invalid UTF-8 lossily, so such values are not checked.
    func testInvalidUTF8IsNotChecked() throws {
        func listing(_ entries: [[UInt8]]) throws -> ConfigParser.Listing {
            var data = Data()
            for entry in entries { data.append(contentsOf: Array("local".utf8) + [0] + entry + [0]) }
            return try ConfigParser.parse(data)
        }
        // A rewrite whose prefix is one byte of a two-byte character: git turns `é…` into `ssh::\xA9…`.
        let rewrite = try listing([
            Array("url.ssh::.insteadof\n".utf8) + [0xC3],
            Array("remote.origin.url\n".utf8) + [0xC3, 0xA9] + Array("x".utf8),
        ])
        XCTAssertEqual(RepoConfigInspector.inspect(rewrite).safetyContext?.fetchableRemotes, [])
        let url = try listing([Array("remote.origin.url\n".utf8) + [0xFF] + Array("x".utf8)])
        XCTAssertEqual(RepoConfigInspector.inspect(url).safetyContext?.fetchableRemotes, [])
    }

    /// SEC-T15-12 for the remote form check: the most expensive checkable listing stays fast, however many remotes it
    /// adds. Every rewrite matches every URL (empty prefix) and passes, so none short-circuits, and each rewritten URL
    /// is one long run of scheme characters. The listing is about 10 MB, the stdout cap of `config --list`.
    func testSECT15_12_RemoteFormCheckIsBounded() {
        var entries: [(ConfigEntry.Scope, String, String?, String, String?)] = []
        for index in 0..<RepoConfigInspector.maximumInsteadOfRewrites {
            let base = String(repeating: "a", count: RepoConfigInspector.maximumCheckedLength - 4) + "\(index + 1000)"
            entries.append((.local, "url", base, "insteadof", ""))
        }
        let url = String(repeating: "b", count: RepoConfigInspector.maximumCheckedLength)
        for index in 0..<2_500 {
            for _ in 0..<RepoConfigInspector.maximumURLsPerRemote {
                entries.append((.local, "remote", "r\(index)", "url", url))
            }
        }
        let clock = ContinuousClock()
        let started = clock.now
        let result = inspect(entries)
        let elapsed = clock.now - started
        XCTAssertLessThan(elapsed, .seconds(20), "\(entries.count) entries took \(elapsed)")
        XCTAssertEqual(fetchable(result).count, RepoConfigInspector.maximumCheckedRemotes, "paths: all checked pass")
    }

    // MARK: - SEC-T5-20: refused before git starts

    private func target() -> Repository {
        Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
    }

    private func plantCanary(named name: String) async throws {
        try await repository.git(["config", "alias.remote-\(name)", "!: > '\(canary.path)/\(name)-ran'"])
    }

    private var canaryNames: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: canary.path))?.sorted() ?? []
    }

    /// The app's fetch arguments without the neutralizing common arguments (the control run).
    private func runWithoutNeutralization() async throws -> ProcessResult {
        let full = repository.environment.arguments(for: FetchCommand.fetch(remote: origin).subcommandArguments())
        var arguments: [String] = []
        var index = 0
        while index < full.count {
            if full[index] == "-c", index + 1 < full.count,
                GitEnvironment.remoteHelperArguments.contains(full[index + 1])
            {
                index += 2
                continue
            }
            arguments.append(full[index])
            index += 1
        }
        XCTAssertEqual(full.count - arguments.count, GitEnvironment.remoteHelperArguments.count)
        return try await ProcessRunner().run(
            ProcessRequest(
                executable: repository.environment.executable, arguments: arguments,
                environment: GitEnvironment.environment(
                    parent: ProcessInfo.processInfo.environment, allowsTransport: true),
                currentDirectory: repository.root, limits: .fetch))
    }

    private func inspectedSafety() async throws -> RepoSafetyContext {
        let listing = try await GitClient(environment: repository.environment)
            .run(.configList, in: repository.root, safety: .preInspection)
        return try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)
    }

    private func assertRefusedBeforeGitStarts(
        canaryName: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await plantCanary(named: canaryName)
        _ = try await runWithoutNeutralization()
        XCTAssertEqual(
            canaryNames, ["\(canaryName)-ran"], "control: the canary must be reachable", file: file, line: line)
        try FileManager.default.removeItem(at: canary.appendingPathComponent("\(canaryName)-ran"))

        let safety = try await inspectedSafety()
        XCTAssertFalse(safety.fetchableRemotes.contains("origin"), file: file, line: line)
        do {
            _ = try await GitClient(environment: repository.environment)
                .fetch(.fetch(remote: origin), in: target(), safety: safety)
            XCTFail("fetch must be refused", file: file, line: line)
        } catch let error as GitError {
            XCTAssertEqual(
                error, .configInspectionFailed(reason: TransportName.nonBuiltInRemoteReason), file: file, line: line)
        }
        XCTAssertEqual(canaryNames, [], file: file, line: line)
    }

    func testSECT5_20_HelperFormsAreRefusedBeforeFetch() async throws {
        for name in ["ssh", "git", "file"] {
            try await repository.git(["remote", "remove", "origin"], allowFailure: true)
            try await repository.git(["remote", "add", "origin", "\(name)::x"])
            try await assertRefusedBeforeGitStarts(canaryName: name)
        }
    }

    func testSECT5_20_RemoteVCSIsRefusedBeforeFetch() async throws {
        try await repository.git(["remote", "add", "origin", "https://127.0.0.1:1/example.git"])
        try await repository.git(["config", "remote.origin.vcs", "ssh"])
        try await assertRefusedBeforeGitStarts(canaryName: "ssh")
    }

    func testSECT5_20_InsteadOfIntoAHelperIsRefusedBeforeFetch() async throws {
        try await repository.git(["remote", "add", "origin", "https://127.0.0.1:1/example.git"])
        try await repository.git(["config", "url.git::x.insteadOf", "https://127.0.0.1:1/"])
        try await assertRefusedBeforeGitStarts(canaryName: "git")
    }

    /// The app's own fetch path: `RepositoryService` reports the refusal per remote and runs nothing.
    func testSECT5_20_RepositoryServiceReportsTheRefusal() async throws {
        try await repository.git(["remote", "add", "origin", "ssh::x"])
        try await plantCanary(named: "ssh")
        let service = RepositoryService(client: GitClient(environment: repository.environment))
        let run = await service.fetch(target())
        guard case .finished(let failures, _) = run else { return XCTFail("got \(run)") }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.remote, origin)
        XCTAssertEqual(failures.first?.reason, .blockedByConfiguration)
        XCTAssertEqual(failures.first?.guidance, TransportName.nonBuiltInRemoteReason)
        XCTAssertEqual(canaryNames, [])
    }

    // MARK: - SEC-T5-21: neutralized even if fetch starts

    /// The pre-check is bypassed (the remote is listed as fetchable), so only the common arguments stand between the
    /// repository's settings and the canary.
    func testSECT5_21_CommonArgumentsNeutralizeTheFallback() async throws {
        for name in ["ssh", "git", "file"] {
            try await repository.git(["remote", "remove", "origin"], allowFailure: true)
            try await repository.git(["remote", "add", "origin", "\(name)::x"])
            try await plantCanary(named: name)
            _ = try await runWithoutNeutralization()
            XCTAssertEqual(canaryNames, ["\(name)-ran"], "control: the canary must be reachable")
            try FileManager.default.removeItem(at: canary.appendingPathComponent("\(name)-ran"))

            let safety = RepoSafetyContext(
                inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil,
                fetchableRemotes: ["origin"])
            do {
                _ = try await GitClient(environment: repository.environment)
                    .fetch(.fetch(remote: origin), in: target(), safety: safety)
                XCTFail("fetch must fail")
            } catch is GitError {}
            XCTAssertEqual(canaryNames, [], name)
        }
    }

    /// The same with a second fallback the repository can turn on: a correction of the missing command name.
    func testSECT5_21_CommonArgumentsNeutralizeTheCorrection() async throws {
        try await repository.git(["remote", "add", "origin", "git::touch \(canary.path)/corrected-ran"])
        try await repository.git(["config", "help.autocorrect", "1"])
        _ = try await runWithoutNeutralization()
        XCTAssertEqual(canaryNames, ["corrected-ran"], "control: the canary must be reachable")
        try FileManager.default.removeItem(at: canary.appendingPathComponent("corrected-ran"))

        let safety = RepoSafetyContext(
            inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil, fetchableRemotes: ["origin"])
        do {
            _ = try await GitClient(environment: repository.environment)
                .fetch(.fetch(remote: origin), in: target(), safety: safety)
            XCTFail("fetch must fail")
        } catch is GitError {}
        XCTAssertEqual(canaryNames, [])
    }

    func testNeutralizingArgumentsCoverEveryAllowedTransport() {
        let names = GitEnvironment.allowedProtocols.split(separator: ":").map { "alias.remote-\($0)=" }
        XCTAssertEqual(
            GitEnvironment.remoteHelperArguments, (names + ["help.autocorrect=0"]).flatMap { ["-c", $0] })
        for pair in stride(from: 0, to: GitEnvironment.remoteHelperArguments.count, by: 2) {
            let slice = Array(GitEnvironment.remoteHelperArguments[pair...pair + 1])
            XCTAssertTrue(
                GitEnvironment.commonArguments.indices.contains { index in
                    index + 1 < GitEnvironment.commonArguments.count
                        && Array(GitEnvironment.commonArguments[index...index + 1]) == slice
                }, "\(slice)")
        }
    }
}
