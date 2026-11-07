import Foundation

@testable import Overgrove

/// Runs one of the repository's own scripts (e.g. `scripts/lint/check-forbidden-apis.sh`) from a test.
///
/// Test support is the one place outside `Overgrove/Execution/` that may name a shell (docs/README.md §2.2). The
/// script runs with a minimal environment and the repository root as its working directory.
enum RepositoryScript {
    /// `.../OvergroveTests/Support/RepositoryScript.swift` → repository root.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Runs `bash <root>/<path> <arguments>`, with `stdin` fed through `executables` when given.
    static func run(
        _ path: String,
        _ arguments: [String] = [],
        stdin: String? = nil,
        executables: TestExecutables
    ) async throws -> ProcessResult {
        let bash = URL(fileURLWithPath: "/bin/bash")
        let script = [bash.path, root.appendingPathComponent(path).path] + arguments
        var executable = bash
        var fullArguments = Array(script.dropFirst())
        if let stdin {
            executable = try executables.stdinWrapper(input: stdin)
            fullArguments = script
        }
        return try await ProcessRunner().run(
            ProcessRequest(
                executable: executable,
                arguments: fullArguments,
                environment: ["PATH": GitEnvironment.path, "HOME": executables.directory.path, "LC_ALL": "C"],
                currentDirectory: root,
                limits: .query
            )
        )
    }
}
