import Foundation

@testable import Overgrove

/// Picks the git the tests run, for the git compatibility matrix (#99, docs/qa/reports/2026-11-08-git-compatibility.md).
///
/// - `OVERGROVE_TEST_GIT`: absolute path of a git executable. Every test that finds git through
///   `GitEnvironment.discoverForTesting` runs it instead of the app's `xcode-select` git.
/// - `OVERGROVE_TEST_GIT_VERSION`: the version that git must report (`2.36.6`). A different version fails discovery,
///   so a matrix run never passes on the wrong git. It is checked with or without an override.
///
/// With xcodebuild, prefix both with `TEST_RUNNER_`. Without them, discovery is exactly the app's (ADR-0008). This lives
/// in test support only: the app's discovery and environment allowlist are unchanged.
enum TestGit {
    static let overrideVariable = "OVERGROVE_TEST_GIT"
    static let expectedVersionVariable = "OVERGROVE_TEST_GIT_VERSION"

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notAbsolute(String)
        case notExecutable(String)
        case versionMismatch(expected: String, found: String)

        var description: String {
            switch self {
            case .notAbsolute(let path): "\(TestGit.overrideVariable) must be an absolute path: \(path)"
            case .notExecutable(let path): "\(TestGit.overrideVariable) is not an executable file: \(path)"
            case .versionMismatch(let expected, let found):
                "\(TestGit.expectedVersionVariable)=\(expected) but the tested git reports \(found)"
            }
        }
    }

    /// A developer directory whose `usr/bin/git` links to the override (the layout `GitEnvironment.discover` expects),
    /// created under `scratch`. `nil` without an override.
    static func developerDirectory(environment: [String: String], scratch: URL) throws -> URL? {
        guard let path = environment[overrideVariable], !path.isEmpty else { return nil }
        guard path.hasPrefix("/") else { throw Failure.notAbsolute(path) }
        guard FileManager.default.isExecutableFile(atPath: path) else { throw Failure.notExecutable(path) }
        let root = scratch.appendingPathComponent("test-git-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("usr/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("git"), withDestinationURL: URL(fileURLWithPath: path))
        return root
    }

    /// The process's override, resolved once per test process.
    fileprivate static let processDeveloperDirectory: Result<URL?, any Error> = Result {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "overgrove-test-git-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        return try developerDirectory(environment: ProcessInfo.processInfo.environment, scratch: scratch)
    }
}

extension GitEnvironment {
    /// `discover` for tests: the app's discovery, or the `OVERGROVE_TEST_GIT` override (`TestGit`).
    ///
    /// `parentEnvironment` is what the git child inherits through the allowlist, as in `discover` (a fixture passes its
    /// isolated HOME). `processEnvironment` is where the override is read; `scratch` holds its developer directory.
    /// Both default to this test process.
    static func discoverForTesting(
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        processEnvironment: [String: String]? = nil,
        scratch: URL? = nil
    ) async throws -> GitEnvironment {
        let directory: URL?
        if let processEnvironment {
            let scratch = scratch ?? FileManager.default.temporaryDirectory
            directory = try TestGit.developerDirectory(environment: processEnvironment, scratch: scratch)
        } else {
            directory = try TestGit.processDeveloperDirectory.get()
        }
        let environment: GitEnvironment
        if let directory {
            environment = try await discover(parentEnvironment: parentEnvironment, developerDirectory: { directory })
        } else {
            environment = try await discover(parentEnvironment: parentEnvironment)
        }
        let expected = (processEnvironment ?? ProcessInfo.processInfo.environment)[TestGit.expectedVersionVariable]
        if let expected, !expected.isEmpty, expected != "\(environment.version)" {
            throw TestGit.Failure.versionMismatch(expected: expected, found: "\(environment.version)")
        }
        return environment
    }
}
