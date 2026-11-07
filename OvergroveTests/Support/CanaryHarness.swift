import Foundation
import XCTest

@testable import Overgrove

/// Runs Overgrove's git commands against the `--malicious` fixture and checks that no payload ran
/// (docs/testing/fixtures.md §8, INT-19, security-review.md T1–T7).
///
/// The hardened path is exactly the app's: `GitClient` with the `RepoSafetyContext` that `RepoConfigInspector`
/// derives from the fixture's own `config --list`. `runPlain` is the negative control: the same subcommand arguments
/// without the common `-c` arguments, the neutralization, and the environment allowlist (and optionally without
/// subcommand-level safety flags such as `--no-textconv`), which must make the payloads fire. Without that control a
/// broken fixture would let every canary check pass silently.
struct CanaryHarness {
    /// One command to run, with the directory it runs in.
    struct Query: Sendable, CustomStringConvertible {
        enum Kind: Sendable {
            case query(ReadOnlyGitCommand)
            case fetch(FetchCommand)
        }

        let kind: Kind
        let directory: URL
        let label: String

        var description: String { label }

        /// Subcommand arguments, as the app would pass them after the common arguments.
        func subcommandArguments() throws -> [String] {
            switch kind {
            case .query(let command): try command.subcommandArguments()
            case .fetch(let command): command.subcommandArguments()
            }
        }
    }

    let fixture: FixtureRepo
    let environment: GitEnvironment
    let client: GitClient
    let inspection: RepoConfigInspection
    let safety: RepoSafetyContext

    /// Inspects the fixture's configuration the way the app does before any other query.
    static func make(fixture: FixtureRepo) async throws -> CanaryHarness {
        let environment = try await GitEnvironment.discover(parentEnvironment: fixture.environment)
        let client = GitClient(environment: environment, parentEnvironment: fixture.environment)
        let config = try await client.run(.configList, in: fixture.repository, safety: .preInspection)
        let inspection = RepoConfigInspector.inspect(try ConfigParser.parse(config.stdout))
        guard let safety = inspection.safetyContext else {
            throw HarnessError.inspectionBlocked(inspection.report)
        }
        try markForRehash(fixture)
        return CanaryHarness(
            fixture: fixture, environment: environment, client: client, inspection: inspection, safety: safety)
    }

    /// Files whose content is unchanged but whose mtime differs from the index, so the next status re-hashes them
    /// through their filter: `src/filter-target.txt` (clean, done by the script) and `docs/manual.md`
    /// (`*.md filter=fixtureproc`, the long-running process filter, T4).
    static let rehashTargets = ["docs/manual.md"]

    private static func markForRehash(_ fixture: FixtureRepo) throws {
        for path in rehashTargets {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_767_225_600)],
                ofItemAtPath: fixture.repository.appendingPathComponent(path).path)
        }
    }

    enum HarnessError: Error {
        case inspectionBlocked(RepoSecurityReport)
        case unresolved(String)
    }

    // MARK: Queries

    /// One query per `ReadOnlyGitCommand` case (plus `fetch origin`), aimed at fixture data that reaches the
    /// payloads: `.txt` files carry the textconv/filter attributes, `malicious/signed` carries a fake signature
    /// (T7), and `origin` has an `uploadpack` override and alternates (T5).
    func queries() async throws -> [Query] {
        let repo = fixture.repository
        let main = try await resolve("refs/heads/main")
        let merge = try await resolve("main~3")  // 0cbcd45, the merge commit (fixtures.md §2.1)
        let mergeParent = try await resolve("main~3^1")
        let signed = try await resolve("refs/heads/malicious/signed")
        let trackedStash = try await resolve("refs/stash@{1}")
        let untrackedStash = try await resolve("refs/stash@{0}")
        let trackedStashBase = try await resolve("refs/stash@{1}^1")
        guard let untracked = PathValidator.worktreeFile(GitPath("untracked.txt"), in: repo) else {
            throw HarnessError.unresolved("untracked.txt")
        }

        func query(_ command: ReadOnlyGitCommand, in directory: URL? = nil, _ label: String) -> Query {
            Query(kind: .query(command), directory: directory ?? repo, label: label)
        }
        let queries: [Query] = [
            query(.version, "version"),
            query(.probeGitDirectory, "probeGitDirectory"),
            query(.probeRepository, "probeRepository"),
            query(.configList, "configList"),
            query(.worktreeList, "worktreeList"),
            query(.status, "status (main worktree: modified .txt files, touched clean and process filter targets)"),
            query(.status, in: fixture.worktree("wt-conflict"), "status (wt-conflict: unmerged index)"),
            query(.refs, "refs"),
            query(
                .aheadBehind(local: try ref("refs/heads/main"), upstream: try ref("refs/remotes/origin/main")),
                "aheadBehind main...origin/main"),
            query(.stashList, "stashList"),
            query(.stashFiles(untrackedStash), "stashFiles stash@{0}"),
            query(
                .stashPatch(trackedStash, path: GitPath("src/stash-target.txt"), fromUntracked: false),
                "stashPatch stash@{1} src/stash-target.txt"),
            query(
                .stashPatch(untrackedStash, path: GitPath("stash-untracked.txt"), fromUntracked: true),
                "stashPatch stash@{0} stash-untracked.txt (untracked part)"),
            query(.graphPage(skip: 0, limit: 500), "graphPage (includes malicious/signed)"),
            query(.commitMeta(signed), "commitMeta malicious/signed"),
            query(.commitFiles(main, firstParent: nil), "commitFiles main"),
            query(.commitFiles(merge, firstParent: mergeParent), "commitFiles merge commit"),
            query(
                .commitPatch(trackedStash, parent: trackedStashBase, path: GitPath("src/stash-target.txt")),
                "commitPatch src/stash-target.txt"),
            query(.worktreeDiff(path: GitPath("src/unstaged-modified.txt"), staged: false), "worktreeDiff unstaged"),
            query(.worktreeDiff(path: GitPath("src/staged-modified.txt"), staged: true), "worktreeDiff staged"),
            query(.worktreeNumstat(staged: false), "worktreeNumstat unstaged"),
            query(.worktreeNumstat(staged: true), "worktreeNumstat staged"),
            query(
                .worktreeNumstat(staged: false), in: fixture.worktree("wt-conflict"), "worktreeNumstat (wt-conflict)"),
            query(.untrackedPreview(untracked), "untrackedPreview untracked.txt"),
            query(.fileHistory(path: GitPath("docs/manual.md"), limit: 100), "fileHistory docs/manual.md"),
            // A `*.txt` file carries the fixture's textconv driver; `log --numstat` reads its blobs (#70).
            query(
                .fileHistory(path: GitPath("src/unstaged-modified.txt"), limit: 100),
                "fileHistory src/unstaged-modified.txt"),
            // The merge-base comparison (#157) reads the working tree, so the touched filter targets are re-hashed.
            query(
                .compareFiles(base: try ref("refs/remotes/origin/main"), includeWorkingTree: true),
                "compareFiles origin/main + working tree"),
            query(
                .compareFiles(base: try ref("refs/heads/malicious/signed"), includeWorkingTree: false),
                "compareFiles malicious/signed (committed)"),
            query(
                .comparePatch(
                    base: try ref("refs/remotes/origin/main"), path: GitPath("src/unstaged-modified.txt"),
                    includeWorkingTree: true),
                "comparePatch src/unstaged-modified.txt + working tree"),
            query(.commitsAhead(base: try ref("refs/heads/malicious/signed"), limit: 100), "commitsAhead"),
            Query(kind: .fetch(.fetch(remote: try remote("origin"))), directory: repo, label: "fetch origin"),
        ]
        return queries
    }

    /// One value per `ReadOnlyGitCommand` case. `caseName(_:)` is an exhaustive switch, so a new command case breaks
    /// the build until it gets a value here; a new value enlarges `allCases`, so INT-19 then fails until `queries()`
    /// runs that command.
    enum CaseName: String, CaseIterable {
        case version, probeGitDirectory, probeRepository, configList, worktreeList, status, refs, aheadBehind
        case stashList, stashFiles
        case stashPatch, graphPage, commitMeta, commitFiles, commitPatch, worktreeDiff, worktreeNumstat
        case untrackedPreview, fileHistory
        case compareFiles, comparePatch, commitsAhead
    }

    static func caseName(_ command: ReadOnlyGitCommand) -> CaseName {
        switch command {
        case .version: .version
        case .probeGitDirectory: .probeGitDirectory
        case .probeRepository: .probeRepository
        case .configList: .configList
        case .worktreeList: .worktreeList
        case .status: .status
        case .refs: .refs
        case .aheadBehind: .aheadBehind
        case .stashList: .stashList
        case .stashFiles: .stashFiles
        case .stashPatch: .stashPatch
        case .graphPage: .graphPage
        case .commitMeta: .commitMeta
        case .commitFiles: .commitFiles
        case .commitPatch: .commitPatch
        case .worktreeDiff: .worktreeDiff
        case .worktreeNumstat: .worktreeNumstat
        case .untrackedPreview: .untrackedPreview
        case .fileHistory: .fileHistory
        case .compareFiles: .compareFiles
        case .comparePatch: .comparePatch
        case .commitsAhead: .commitsAhead
        }
    }

    // MARK: Running

    /// Runs a query the way the app does. Throws if git fails: a failing command may stop before the code path
    /// that would run a payload, so a failure must not count as "no canary".
    func runHardened(_ query: Query) async throws {
        switch query.kind {
        case .query(let command):
            let safety = command.requiresInspection ? safety : .preInspection
            _ = try await client.run(command, in: query.directory, safety: safety)
        case .fetch(let command):
            // The fixture's main worktree: fetch serializes per repository (#76).
            let repository = Repository(
                rootURL: query.directory,
                commonGitDirectoryURL: query.directory.appendingPathComponent(".git", isDirectory: true),
                isBare: false
            )
            _ = try await client.fetch(command, in: repository, safety: safety)
        }
    }

    /// Negative control: the same subcommand with plain git, as a typical client runs it. Only the fixture's isolated
    /// HOME and a fixed PATH are set, and system/global configuration is off, so the repository's own configuration
    /// is the only thing that differs from a clean run. (The hardened run reads system configuration like the app
    /// does; HOME is isolated in both, so global configuration is empty either way.)
    ///
    /// - Parameter dropping: Subcommand-level safety flags to remove as well, e.g. `--no-textconv`, to prove that
    ///   those flags (not the absence of a code path) are what stop a payload.
    func runPlain(
        _ query: Query,
        dropping: Set<String> = [],
        limits: ProcessLimits = .fetch
    ) async throws -> ProcessResult {
        let arguments = try query.subcommandArguments()
        let missing = dropping.subtracting(arguments)
        guard missing.isEmpty else { throw HarnessError.unresolved("\(query) has no \(missing.sorted())") }
        return try await ProcessRunner().run(
            ProcessRequest(
                executable: environment.executable,
                arguments: arguments.filter { !dropping.contains($0) },
                environment: [
                    "HOME": fixture.home.path,
                    "PATH": GitEnvironment.path,
                    "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_CONFIG_GLOBAL": "/dev/null",
                ],
                currentDirectory: query.directory,
                limits: limits
            )
        )
    }

    // MARK: Setup

    /// Plain git for setup that runs no repository program, such as `config` writes. Fails on a non-zero exit.
    @discardableResult
    func runPlainSetup(_ arguments: [String]) async throws -> ProcessResult {
        try await setup(
            arguments,
            environment: ["HOME": fixture.home.path, "PATH": GitEnvironment.path, "GIT_CONFIG_NOSYSTEM": "1"])
    }

    /// git with the app's common arguments and neutralization, for setup that would otherwise run a planted program
    /// (a ref update runs the reference-transaction hook). Fails on a non-zero exit.
    @discardableResult
    func runHardenedSetup(_ arguments: [String]) async throws -> ProcessResult {
        try await setup(
            environment.arguments(for: arguments, neutralization: safety.neutralization),
            environment: GitEnvironment.environment(parent: fixture.environment))
    }

    /// Makes the next fetch of origin update a ref again: hooks and auto maintenance only run when there is work.
    func forgetRemoteOnlyBranch() async throws {
        try await runHardenedSetup(["update-ref", "-d", "refs/remotes/origin/feat/remote-only"])
    }

    private func setup(_ arguments: [String], environment childEnvironment: [String: String]) async throws
        -> ProcessResult
    {
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: environment.executable,
                arguments: arguments,
                environment: childEnvironment,
                currentDirectory: fixture.repository,
                limits: .query
            )
        )
        guard result.succeeded else {
            throw HarnessError.unresolved("setup \(arguments): \(String(decoding: result.stderr, as: UTF8.self))")
        }
        return result
    }

    // MARK: Helpers

    /// `rev-parse --verify` with the app's hardened arguments (rev-parse itself is not an app command).
    func resolve(_ revision: String) async throws -> ObjectID {
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: environment.executable,
                arguments: environment.arguments(
                    for: ["rev-parse", "--verify", "--end-of-options", revision],
                    neutralization: safety.neutralization
                ),
                environment: GitEnvironment.environment(parent: fixture.environment),
                currentDirectory: fixture.repository,
                limits: .query
            )
        )
        let hex = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, let oid = ObjectID(hex) else { throw HarnessError.unresolved(revision) }
        return oid
    }

    private func ref(_ name: String) throws -> FullRefName {
        guard let ref = FullRefName(name) else { throw HarnessError.unresolved(name) }
        return ref
    }

    private func remote(_ name: String) throws -> RemoteName {
        guard let remote = RemoteName(name) else { throw HarnessError.unresolved(name) }
        return remote
    }
}
