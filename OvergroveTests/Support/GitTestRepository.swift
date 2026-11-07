import Foundation

@testable import Overgrove

/// A throwaway git repository driven through the app's own hardened invocation (GitEnvironment + ProcessRunner).
struct GitTestRepository {
    let root: URL
    let environment: GitEnvironment

    static func make() async throws -> GitTestRepository {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("overgrove-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = GitTestRepository(root: root, environment: try await GitEnvironment.discover())
        try await repository.git(["init", "-q", "-b", "main"])
        return repository
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs git with the common safety arguments. Setup commits get a fixed identity.
    @discardableResult
    func git(_ subcommand: [String], allowFailure: Bool = false) async throws -> ProcessResult {
        let identity = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"]
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: environment.executable,
                arguments: environment.arguments(for: subcommand, neutralization: identity),
                // Setup pushes and clones between local repositories, so it needs the transport list (#215).
                environment: GitEnvironment.environment(
                    parent: ProcessInfo.processInfo.environment, allowsTransport: true),
                currentDirectory: root,
                limits: .query
            )
        )
        if !allowFailure && result.termination != .exited(code: 0) {
            throw NSError(
                domain: "GitTestRepository",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(decoding: result.stderr, as: UTF8.self)]
            )
        }
        return result
    }

    func write(_ name: String, _ contents: String) throws {
        try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }
}
