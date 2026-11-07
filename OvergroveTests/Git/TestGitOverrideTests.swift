import Foundation
import XCTest

@testable import Overgrove

/// The test-only git override for the compatibility matrix (#99): `OVERGROVE_TEST_GIT` picks the git every test runs,
/// and `OVERGROVE_TEST_GIT_VERSION` makes the run fail when that git reports a different version.
final class TestGitOverrideTests: XCTestCase {
    private var executables: TestExecutables!

    override func setUpWithError() throws {
        executables = try TestExecutables()
    }

    override func tearDown() {
        executables.remove()
    }

    private func fakeGit(versionLine: String) throws -> URL {
        try executables.fakeDeveloperDirectory(versionLine: versionLine).appendingPathComponent("usr/bin/git")
    }

    func testWithoutAnOverrideTheAppDiscoveryIsUsed() async throws {
        XCTAssertNil(try TestGit.developerDirectory(environment: [:], scratch: executables.directory))

        let tested = try await GitEnvironment.discoverForTesting(processEnvironment: [:])
        let app = try await GitEnvironment.discover()
        XCTAssertEqual(tested.executable, app.executable)
        XCTAssertEqual(tested.version, app.version)
    }

    func testTheOverrideGitIsTheOneThatRuns() async throws {
        let git = try fakeGit(versionLine: "git version 2.36.6")
        let tested = try await GitEnvironment.discoverForTesting(
            processEnvironment: [TestGit.overrideVariable: git.path], scratch: executables.directory)
        XCTAssertEqual(tested.version, GitVersion(major: 2, minor: 36, patch: 6))
        XCTAssertTrue(tested.executable.path.hasSuffix("/usr/bin/git"))
        XCTAssertEqual(tested.executable.resolvingSymlinksInPath().path, git.resolvingSymlinksInPath().path)
    }

    func testAMatchingExpectedVersionPasses() async throws {
        let git = try fakeGit(versionLine: "git version 2.54.0 (Apple Git-157)")
        let tested = try await GitEnvironment.discoverForTesting(
            processEnvironment: [TestGit.overrideVariable: git.path, TestGit.expectedVersionVariable: "2.54.0"],
            scratch: executables.directory)
        XCTAssertEqual(tested.version, GitVersion(major: 2, minor: 54, patch: 0))
    }

    func testAnExpectedVersionMismatchFails() async throws {
        let git = try fakeGit(versionLine: "git version 2.54.0")
        do {
            _ = try await GitEnvironment.discoverForTesting(
                processEnvironment: [TestGit.overrideVariable: git.path, TestGit.expectedVersionVariable: "2.36.6"],
                scratch: executables.directory)
            XCTFail("expected a version mismatch")
        } catch let error as TestGit.Failure {
            XCTAssertEqual(error, .versionMismatch(expected: "2.36.6", found: "2.54.0"))
        }
    }

    /// Without an override, the expected version is checked against the app's own git, so a matrix run that forgot
    /// `OVERGROVE_TEST_GIT` still fails instead of silently testing the default git.
    func testAnExpectedVersionIsCheckedWithoutAnOverrideToo() async throws {
        do {
            _ = try await GitEnvironment.discoverForTesting(
                processEnvironment: [TestGit.expectedVersionVariable: "2.0.0"], scratch: executables.directory)
            XCTFail("expected a version mismatch")
        } catch let error as TestGit.Failure {
            guard case .versionMismatch(expected: "2.0.0", _) = error else { return XCTFail("got \(error)") }
        }
    }

    func testARelativeOverrideIsRejected() {
        XCTAssertThrowsError(
            try TestGit.developerDirectory(
                environment: [TestGit.overrideVariable: "bin/git"], scratch: executables.directory)
        ) { error in
            XCTAssertEqual(error as? TestGit.Failure, .notAbsolute("bin/git"))
        }
    }

    func testAMissingOverrideIsRejected() {
        let missing = executables.directory.appendingPathComponent("no-such-git").path
        XCTAssertThrowsError(
            try TestGit.developerDirectory(
                environment: [TestGit.overrideVariable: missing], scratch: executables.directory)
        ) { error in
            XCTAssertEqual(error as? TestGit.Failure, .notExecutable(missing))
        }
    }

    /// The git this test process actually runs. In a matrix run (`TEST_RUNNER_OVERGROVE_TEST_GIT_VERSION`), this is
    /// the check that the whole run used the requested git.
    func testThisRunUsesTheRequestedGit() async throws {
        let environment = try await GitEnvironment.discoverForTesting()
        let expected = ProcessInfo.processInfo.environment[TestGit.expectedVersionVariable]
        try XCTSkipIf(
            expected == nil, "no \(TestGit.expectedVersionVariable): running the app's git \(environment.version)")
        XCTAssertEqual("\(environment.version)", expected)
    }
}
