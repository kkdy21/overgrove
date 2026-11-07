import Foundation
import OSLog
import XCTest

@testable import Overgrove

/// T16 (security-review.md §2): nothing the app handles reaches the unified log in a form that leaks credentials or
/// raw remote URLs.
final class LogLeakTests: XCTestCase {
    /// Entries this process wrote at or after `start`, as their composed messages.
    private func messages(since start: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: start)
        return try store.getEntries(at: position).compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
    }

    /// SEC-T16-01: run the app's git path on a repository whose remote carries credentials (the fixture's `mirror`
    /// remote, `https://<user>:<password>@example.invalid/…`), including a fetch that fails and reports stderr, then
    /// collect this process's log with `OSLogStore`: no credential, raw remote URL, or token pattern appears.
    ///
    /// The app logs nothing today; the check guards whatever logging is added (overview.md §7 requires `.private` and
    /// masking). Public markers logged by the test before and after the app's work prove the store returned this
    /// process's entries for the whole span, so the check cannot pass just because collection failed or stopped early.
    ///
    /// Scope: this proves no credential appears in *readable* log text. A value logged with `privacy: .private`
    /// shows as `<private>` here even unmasked, so masking before logging is enforced by `MaskedText`, not by this
    /// test. `.info` entries are collected too (asserted below); `.debug` entries are not persisted by default.
    func testSECT16_01_LogsContainNoCredentialsOrRawRemoteURLs() async throws {
        let start = Date().addingTimeInterval(-1)
        let id = UUID().uuidString
        let marker = "SEC-T16-01 start \(id)"
        let infoMarker = "SEC-T16-01 info \(id)"
        let endMarker = "SEC-T16-01 end \(id)"
        let logger = Logger(subsystem: "io.github.kkdy21.overgrove.tests", category: "security")
        logger.notice("\(marker, privacy: .public)")
        logger.info("\(infoMarker, privacy: .public)")

        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let config = try await context.run(.configList)
        let inspection = RepoConfigInspector.inspect(try ConfigParser.parse(config))
        let mirror = try XCTUnwrap(inspection.remotes.first { $0.name.value == "mirror" })
        let components = try XCTUnwrap(URLComponents(string: mirror.url))
        let user = try XCTUnwrap(components.user)
        let password = try XCTUnwrap(components.password)
        XCTAssertFalse(mirror.displayURL.contains(password), "the display URL is masked")

        // A fetch of the credentialed remote fails (example.invalid) and carries git's stderr into the error.
        do {
            _ = try await context.client.fetch(
                .fetch(remote: mirror.name), in: context.repository, safety: context.safety)
            XCTFail("fetching example.invalid should fail")
        } catch let error as GitError {
            for (number, text) in [error.message, error.detail?.text ?? ""].enumerated() {
                XCTAssertFalse(text.contains(password), "error text #\(number) is not masked")
            }
        }
        logger.notice("\(endMarker, privacy: .public)")

        // Entries can take a moment to become readable.
        var collected: [String] = []
        let found = await eventually(timeout: .seconds(10)) {
            collected = (try? self.messages(since: start)) ?? []
            return collected.contains { $0.contains(endMarker) }
        }
        XCTAssertTrue(found, "control: OSLogStore must return entries up to the end marker (\(collected.count) read)")
        XCTAssertTrue(collected.contains { $0.contains(marker) }, "control: the start marker was collected")
        XCTAssertTrue(collected.contains { $0.contains(infoMarker) }, "control: .info entries are collected")

        let forbidden = [
            password, "\(user):\(password)@", mirror.url, "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
        ]
        // Failure messages name the pattern and entry index only, so a leak is not repeated in the test output.
        for (index, message) in collected.enumerated() where !message.contains(id) {
            for (number, secret) in forbidden.enumerated() {
                XCTAssertFalse(message.contains(secret), "log entry \(index) contains forbidden pattern #\(number)")
            }
        }
    }
}
