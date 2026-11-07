import Foundation
import XCTest

@testable import Overgrove

/// Runs the app's real git path against a fixture: `configList` → `RepoConfigInspector` → `RepoSafetyContext` →
/// `GitClient`, with the fixture's isolated environment (docs/testing/fixtures.md §9).
///
/// `plainGit` is an independent oracle: stock git with no Overgrove arguments, for comparing parsed results with what
/// git itself reports (D2). Use it only on the normal fixture; the malicious one would run its payloads.
struct IntegrationContext {
    let fixture: FixtureRepo
    let environment: GitEnvironment
    let client: GitClient
    let safety: RepoSafetyContext

    static func make(fixture: FixtureRepo) async throws -> IntegrationContext {
        let environment = try await GitEnvironment.discover(parentEnvironment: fixture.environment)
        let client = GitClient(environment: environment, parentEnvironment: fixture.environment)
        let config = try await client.run(.configList, in: fixture.repository, safety: .preInspection)
        let inspection = RepoConfigInspector.inspect(try ConfigParser.parse(config.stdout))
        guard let safety = inspection.safetyContext else {
            throw Failure.inspectionBlocked(inspection.report.blockingReason ?? "")
        }
        return IntegrationContext(fixture: fixture, environment: environment, client: client, safety: safety)
    }

    enum Failure: Error {
        case inspectionBlocked(String)
        case truncated(String)
        case plainGitFailed(String)
    }

    /// stdout of an app command. Truncated output fails: the fixture is small, so truncation means a bug.
    func run(_ command: ReadOnlyGitCommand, in directory: URL? = nil) async throws -> Data {
        let safety = command.requiresInspection ? safety : .preInspection
        let output = try await client.run(command, in: directory ?? fixture.repository, safety: safety)
        guard !output.isTruncated else { throw Failure.truncated("\(command)") }
        return output.stdout
    }

    func status(of worktree: URL) async throws -> WorkingState {
        try StatusParser.parse(try await run(.status, in: worktree))
    }

    func worktrees() async throws -> [Worktree] {
        try WorktreeParser.parse(try await run(.worktreeList)).worktrees
    }

    func graph(limit: Int = 500) async throws -> [CommitNode] {
        try LogParser.parseGraph(try await run(.graphPage(skip: 0, limit: limit))).commits
    }

    func refs() async throws -> RefParser.Listing {
        try RefParser.parse(try await run(.refs))
    }

    /// The full object ID of a commit in the graph whose ID starts with `prefix` (fixtures.md uses 7-digit IDs).
    func commit(_ prefix: String, in graph: [CommitNode]) throws -> CommitNode {
        let matches = graph.filter { $0.oid.hex.hasPrefix(prefix) }
        guard matches.count == 1, let match = matches.first else {
            throw Failure.plainGitFailed("expected one commit with prefix \(prefix), found \(matches.count)")
        }
        return match
    }

    /// Stock git with only the fixture's HOME and system configuration off: what any other client would see.
    func plainGit(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: environment.executable,
                arguments: arguments,
                environment: [
                    "HOME": fixture.home.path, "PATH": GitEnvironment.path, "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C",
                ],
                currentDirectory: directory,
                limits: .query
            )
        )
        guard result.succeeded else {
            throw Failure.plainGitFailed("\(arguments): \(String(decoding: result.stderr, as: UTF8.self))")
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}

/// File counts by category, computed independently of `StatusParser`.
struct StatusCounts: Equatable, CustomStringConvertible {
    var staged = 0
    var unstaged = 0
    var untracked = 0
    var conflicted = 0

    var description: String {
        "staged=\(staged) unstaged=\(unstaged) untracked=\(untracked) conflicted=\(conflicted)"
    }

    init(staged: Int = 0, unstaged: Int = 0, untracked: Int = 0, conflicted: Int = 0) {
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
    }

    init(_ state: WorkingState) {
        self.init(
            staged: state.staged.count, unstaged: state.unstaged.count, untracked: state.untracked.count,
            conflicted: state.conflicted.count)
    }

    private static let conflictCodes: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]

    /// From `git status --porcelain` (v1, one entry per line, `XY path`). Paths with special characters are quoted
    /// on a single line, and renames are `R  old -> new`, so counting by the XY prefix needs no path parsing.
    init(porcelainV1 text: String) {
        self.init()
        for line in text.split(separator: "\n") where line.count >= 3 {
            let xy = String(line.prefix(2))
            if xy == "??" {
                untracked += 1
            } else if Self.conflictCodes.contains(xy) {
                conflicted += 1
            } else {
                if xy.first != " " { staged += 1 }
                if xy.last != " " { unstaged += 1 }
            }
        }
    }
}
