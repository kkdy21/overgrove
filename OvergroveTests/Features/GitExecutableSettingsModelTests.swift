import Foundation
import XCTest

@testable import Overgrove

/// The Settings › Advanced git executable row (screens.md S-08, ADR-0019, #106), with stubbed discovery.
@MainActor
final class GitExecutableSettingsModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "overgrove-git-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private final class Calls: @unchecked Sendable {
        var resolved: [String?] = []
        var resets = 0
    }

    private nonisolated static func environment(_ path: String, _ version: GitVersion) -> GitEnvironment {
        GitEnvironment(executable: URL(fileURLWithPath: path), version: version)
    }

    private func model(
        settings: AppSettings, calls: Calls, signed: Bool = false,
        resolve: @escaping @Sendable (String?) throws -> GitEnvironment
    ) -> GitExecutableSettingsModel {
        GitExecutableSettingsModel(
            settings: settings, repositories: { [] },
            resolve: { path, _ in
                calls.resolved.append(path)
                return try resolve(path)
            },
            isAppleSigned: { _ in signed },
            resetSharedClient: { calls.resets += 1 })
    }

    private nonisolated static let current = GitVersion(major: 2, minor: 54, patch: 0)
    private nonisolated static let old = GitVersion(major: 2, minor: 40, patch: 0)

    func testTheDefaultIsShownWithItsRealPathVersionAndSignature() async {
        let settings = AppSettings(defaults: defaults)
        let calls = Calls()
        let model = model(settings: settings, calls: calls, signed: true) { _ in
            Self.environment("/Applications/Xcode.app/Contents/Developer/usr/bin/git", Self.current)
        }
        await model.refresh()
        XCTAssertEqual(calls.resolved, [nil])
        XCTAssertEqual(
            model.state,
            .ready(
                GitExecutableReport(
                    entered: nil, resolvedPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
                    version: Self.current, isAppleSigned: true)))
        XCTAssertTrue(model.isDefault)
    }

    func testAnAcceptedChoiceIsSavedAndTheSharedClientReset() async {
        let settings = AppSettings(defaults: defaults)
        let calls = Calls()
        let model = model(settings: settings, calls: calls) { path in
            path == nil
                ? Self.environment("/xcode/git", Self.current) : Self.environment("/opt/homebrew/Cellar/git", Self.old)
        }
        await model.choose(path: "/opt/homebrew/bin/git")

        XCTAssertEqual(settings.gitExecutablePath, "/opt/homebrew/bin/git")
        XCTAssertEqual(defaults.string(forKey: AppSettings.gitExecutablePathKey), "/opt/homebrew/bin/git")
        XCTAssertEqual(calls.resets, 1)
        guard case .ready(let report) = model.state else { return XCTFail("got \(model.state)") }
        XCTAssertEqual(report.entered, "/opt/homebrew/bin/git")
        XCTAssertFalse(report.isAppleSigned)
        XCTAssertFalse(report.canFetchPartialClones, "2.40.0 is below lazyFetchControlVersion")
        XCTAssertNil(model.choiceError)
    }

    /// A choice that fails the rules is not saved; the previous git stays and the reason is shown.
    func testARejectedChoiceIsNotSaved() async {
        let settings = AppSettings(defaults: defaults)
        let calls = Calls()
        let model = model(settings: settings, calls: calls) { path in
            guard path == nil else {
                throw GitError.chosenExecutableRejected(path: path!, reason: "The file is not executable.")
            }
            return Self.environment("/xcode/git", Self.current)
        }
        await model.refresh()
        await model.choose(path: "/Users/example/bin/git")

        XCTAssertNil(settings.gitExecutablePath)
        XCTAssertNil(defaults.string(forKey: AppSettings.gitExecutablePathKey))
        XCTAssertEqual(calls.resets, 0)
        XCTAssertEqual(model.choiceError, "The file is not executable.")
        guard case .ready(let report) = model.state else { return XCTFail("got \(model.state)") }
        XCTAssertNil(report.entered, "still the default")
    }

    func testAnOldChoiceIsNotSaved() async {
        let settings = AppSettings(defaults: defaults)
        let model = model(settings: settings, calls: Calls()) { path in
            guard path == nil else {
                throw GitError.unsupportedVersion(found: GitVersion(major: 2, minor: 30, patch: 0))
            }
            return Self.environment("/xcode/git", Self.current)
        }
        await model.choose(path: "/usr/local/bin/git")
        XCTAssertNil(settings.gitExecutablePath)
        XCTAssertEqual(
            model.choiceError, GitError.unsupportedVersion(found: GitVersion(major: 2, minor: 30, patch: 0)).message)
    }

    /// Choosing the `/usr/bin/git` shim stores nothing: it is the default (ADR-0019 §1).
    func testChoosingTheShimMeansTheDefault() async {
        let settings = AppSettings(defaults: defaults)
        settings.gitExecutablePath = "/opt/homebrew/bin/git"
        let calls = Calls()
        let model = model(settings: settings, calls: calls) { _ in Self.environment("/xcode/git", Self.current) }
        await model.choose(path: "/usr/bin/git")
        XCTAssertNil(settings.gitExecutablePath)
        XCTAssertEqual(calls.resets, 1)
    }

    /// A stored choice that no longer passes is shown as such, with Use Default (fail closed, ADR-0019 §4).
    func testAStoredChoiceThatFailsIsShownAndCanBeReset() async {
        let settings = AppSettings(defaults: defaults)
        settings.gitExecutablePath = "/opt/homebrew/bin/git"
        let calls = Calls()
        let model = model(settings: settings, calls: calls) { path in
            guard path == nil else {
                throw GitError.chosenExecutableRejected(path: path!, reason: "No file exists at that path.")
            }
            return Self.environment("/xcode/git", Self.current)
        }
        await model.refresh()
        XCTAssertEqual(model.state, .rejected(path: "/opt/homebrew/bin/git", reason: "No file exists at that path."))
        XCTAssertFalse(model.isDefault)
        XCTAssertEqual(calls.resets, 1, "a refused stored choice drops the shared client, so queries really stop")

        await model.useDefault()
        XCTAssertNil(settings.gitExecutablePath)
        XCTAssertEqual(calls.resets, 2)
        guard case .ready(let report) = model.state else { return XCTFail("got \(model.state)") }
        XCTAssertNil(report.entered)
    }

    func testPartialCloneNoteFollowsTheControlVersion() {
        let below = GitExecutableReport(
            entered: nil, resolvedPath: "/g", version: GitVersion(major: 2, minor: 45, patch: 0), isAppleSigned: false)
        let at = GitExecutableReport(
            entered: nil, resolvedPath: "/g", version: GitEnvironment.lazyFetchControlVersion, isAppleSigned: false)
        XCTAssertFalse(below.canFetchPartialClones)
        XCTAssertTrue(at.canFetchPartialClones)
    }
}
