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

    /// The override's executable, checked to be an absolute path to an executable file. `nil` without an override.
    ///
    /// It is probed directly (`GitEnvironment.probe`) and skips ADR-0019's path and ownership rules, which are for a
    /// git chosen in Settings: matrix runs use gits built in temporary directories. The version checks still apply.
    static func executable(environment: [String: String]) throws -> URL? {
        guard let path = environment[overrideVariable], !path.isEmpty else { return nil }
        guard path.hasPrefix("/") else { throw Failure.notAbsolute(path) }
        guard FileManager.default.isExecutableFile(atPath: path) else { throw Failure.notExecutable(path) }
        return URL(fileURLWithPath: path)
    }

    /// The process's override, resolved once per test process.
    fileprivate static let processExecutable: Result<URL?, any Error> = Result {
        try executable(environment: ProcessInfo.processInfo.environment)
    }
}

extension GitEnvironment {
    /// `discover` for tests: the app's discovery, or the `OVERGROVE_TEST_GIT` override (`TestGit`).
    ///
    /// `parentEnvironment` is what the git child inherits through the allowlist, as in `discover` (a fixture passes its
    /// isolated HOME). `processEnvironment` is where the override is read; it defaults to this test process.
    static func discoverForTesting(
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        processEnvironment: [String: String]? = nil
    ) async throws -> GitEnvironment {
        let override =
            try processEnvironment.map { try TestGit.executable(environment: $0) } ?? TestGit.processExecutable.get()
        let environment: GitEnvironment
        if let override {
            environment = try await probe(executable: override, parentEnvironment: parentEnvironment)
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

extension GitEnvironment {
    /// For test fixtures that use a local repository as a stand-in for a network remote. Before
    /// `lazyFetchControlVersion` the app refuses local remotes (#361, SEC-T5-23), so on such a git (`OVERGROVE_TEST_GIT`)
    /// these fixtures report that version instead, and keep testing the other layers of fetch (hooks, uploadpack,
    /// ref scope, …) on the git under test. The only other gate that reads the version is the partial clone check, and
    /// these fixtures are not partial clones. Tests of the refusal itself use the real version.
    var fetchingLocalRemotesForTesting: GitEnvironment {
        GitClient.allowsLocalTransport(version)
            ? self : GitEnvironment(executable: executable, version: GitEnvironment.lazyFetchControlVersion)
    }
}
