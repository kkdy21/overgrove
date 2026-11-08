import Foundation
import XCTest

@testable import Overgrove

/// A small purpose-built repository for SEC tests whose scenario the `--malicious` fixture does not have
/// (submodules, tracked `.gitattributes`, `.git/hooks/`, `required=true` filters, credential helper orders…).
///
/// Layout under `TestExecutables.directory`: `home/` (isolated HOME, so the runner's global configuration never
/// applies), `canary/` (payload records), and the repositories a test creates. Two ways to run git:
/// - `app…` methods: the app's real path. `RepoConfigInspector` inspects the repository's configuration, and the
///   resulting `RepoSafetyContext` goes to `GitClient` with the isolated environment.
/// - `plain(_:)`: stock git with only HOME and `GIT_CONFIG_NOSYSTEM`, the negative control and the setup tool.
///   Setup must finish before a payload is planted, or setup itself could run it.
struct SecurityScenario {
    let executables: TestExecutables
    let environment: GitEnvironment
    let home: URL
    let canary: URL

    static func make(_ executables: TestExecutables) async throws -> SecurityScenario {
        let home = executables.directory.appendingPathComponent("home", isDirectory: true)
        let canary = executables.directory.appendingPathComponent("canary", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: canary, withIntermediateDirectories: true)
        let parent = ["HOME": home.path, "TMPDIR": executables.directory.path]
        let environment = try await GitEnvironment.discoverForTesting(parentEnvironment: parent)
        return SecurityScenario(executables: executables, environment: environment, home: home, canary: canary)
    }

    /// The parent environment the app would pass to `GitClient`: only the isolated HOME and a temporary directory.
    var parentEnvironment: [String: String] {
        ["HOME": home.path, "TMPDIR": executables.directory.path]
    }

    /// A new directory for a repository, e.g. `directory("super")`.
    func directory(_ name: String) -> URL {
        executables.directory.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: Payloads and canaries

    /// Path of a payload script that records `id` in `canary/`.
    func payload(_ id: String, tail: String = "exit 0") throws -> String {
        try executables.canaryPayload(id, canary: canary, tail: tail).path
    }

    func canaries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: canary.path)) ?? []).sorted()
    }

    /// Lines recorded by one payload, in order.
    func records(_ id: String) -> [String] {
        let text = (try? String(contentsOf: canary.appendingPathComponent(id), encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func clearCanaries() throws {
        for name in canaries() { try FileManager.default.removeItem(at: canary.appendingPathComponent(name)) }
    }

    // MARK: Plain git (setup and negative control)

    /// Stock git: fixed identity for commits, local `file` transport allowed for submodule setup, nothing else.
    @discardableResult
    func plain(
        _ arguments: [String],
        in directory: URL,
        stdin: String? = nil,
        limits: ProcessLimits = .fetch,
        requireSuccess: Bool = false
    ) async throws -> ProcessResult {
        let gitArguments =
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "protocol.file.allow=always"]
            + arguments
        let result = try await launch(
            gitArguments, in: directory, environment: plainEnvironment, stdin: stdin, limits: limits)
        if requireSuccess && !result.succeeded {
            throw ScenarioError.gitFailed(arguments, String(decoding: result.stderr, as: UTF8.self))
        }
        return result
    }

    /// Writes one configuration value with plain git (a config write runs no repository program).
    func config(_ key: String, _ value: String, in repository: URL) async throws {
        try await plain(["config", key, value], in: repository, requireSuccess: true)
    }

    private var plainEnvironment: [String: String] {
        ["HOME": home.path, "PATH": GitEnvironment.path, "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C"]
    }

    enum ScenarioError: Error {
        case gitFailed([String], String)
        case blocked(String)
    }

    // MARK: The app's path

    /// `configList` → `RepoConfigInspector`, as the app does before any other query in `repository`.
    func inspect(_ repository: URL) async throws -> RepoConfigInspection {
        let config = try await client().run(.configList, in: repository, safety: .preInspection)
        return RepoConfigInspector.inspect(try ConfigParser.parse(config.stdout))
    }

    func client() -> GitClient {
        GitClient(environment: environment.fetchingLocalRemotesForTesting, parentEnvironment: parentEnvironment)
    }

    /// Inspects `repository` and runs an app command with the resulting safety context.
    func app(_ command: ReadOnlyGitCommand, in directory: URL, repository: URL? = nil) async throws -> GitOutput {
        let inspection = try await inspect(repository ?? directory)
        guard let safety = inspection.safetyContext else {
            throw ScenarioError.blocked(inspection.report.blockingReason ?? "")
        }
        return try await client().run(command, in: directory, safety: safety)
    }

    /// The app's common arguments, neutralization and environment around a subcommand the test changed (for
    /// isolating which single flag stops a vector). Not an app command: `GitClient` only takes `ReadOnlyGitCommand`.
    func appArguments(_ subcommand: [String], in directory: URL, repository: URL? = nil) async throws -> ProcessResult {
        let inspection = try await inspect(repository ?? directory)
        guard let safety = inspection.safetyContext else {
            throw ScenarioError.blocked(inspection.report.blockingReason ?? "")
        }
        return try await launch(
            environment.arguments(for: subcommand, neutralization: safety.neutralization),
            in: directory,
            environment: GitEnvironment.environment(parent: parentEnvironment),
            stdin: nil,
            limits: .query
        )
    }

    /// Inspects `repository` and runs `git fetch <remote>` the way the app does.
    func appFetch(_ remote: String, in repository: URL) async throws -> GitOutput {
        let inspection = try await inspect(repository)
        guard let safety = inspection.safetyContext, let name = RemoteName(remote) else {
            throw ScenarioError.blocked(inspection.report.blockingReason ?? remote)
        }
        let model = Repository(
            rootURL: repository, commonGitDirectoryURL: repository.appendingPathComponent(".git"), isBare: false)
        return try await client().fetch(.fetch(remote: name), in: model, safety: safety)
    }

    /// `git credential fill` with exactly the arguments and environment of the app's fetch (common arguments,
    /// neutralization, and the fetch-only credential reset and re-insertion). Stand-in for HTTP authentication,
    /// which needs a server (fixtures.md §8.2, M35–38).
    func appCredentialFill(in repository: URL, input: String) async throws -> ProcessResult {
        let inspection = try await inspect(repository)
        guard let safety = inspection.safetyContext else {
            throw ScenarioError.blocked(inspection.report.blockingReason ?? "")
        }
        let arguments = environment.arguments(
            for: ["credential", "fill"],
            neutralization: safety.neutralization,
            fetchAuthentication: safety.fetchAuthentication
        )
        return try await launch(
            arguments,
            in: repository,
            environment: GitEnvironment.environment(
                parent: parentEnvironment, trustedSSHCommand: safety.trustedSSHCommand, allowsTransport: true),
            stdin: input,
            limits: .query
        )
    }

    // MARK: Launching

    private func launch(
        _ arguments: [String],
        in directory: URL,
        environment childEnvironment: [String: String],
        stdin: String?,
        limits: ProcessLimits
    ) async throws -> ProcessResult {
        var executable = environment.executable
        var fullArguments = arguments
        if let stdin {
            executable = try executables.stdinWrapper(input: stdin)
            fullArguments = [environment.executable.path] + arguments
        }
        return try await ProcessRunner().run(
            ProcessRequest(
                executable: executable,
                arguments: fullArguments,
                environment: childEnvironment,
                currentDirectory: directory,
                limits: limits
            )
        )
    }
}
