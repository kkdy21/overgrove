import Foundation
import XCTest

@testable import Overgrove

/// Fixture builders that fail the test instead of crashing the test host (#312). A forced `try` that throws stops
/// the whole host with `swift_unexpectedError`, and every test after it leaves no result;
/// `scripts/lint/check-test-crashes.sh` keeps it out of the test target.
enum TestFixtures {
    /// A patch parsed from `text`. When the parser rejects it (a parser change), the calling test fails and gets an
    /// empty listing.
    static func patch(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> PatchParser.Listing {
        do {
            return try PatchParser.parse(Data(text.utf8))
        } catch {
            XCTFail("fixture patch rejected: \(error)", file: file, line: line)
            return PatchParser.Listing(files: [], isPartial: false)
        }
    }

    /// The subcommand arguments of `command`; on failure the calling test fails and gets none.
    static func arguments(
        _ command: ReadOnlyGitCommand, file: StaticString = #filePath, line: UInt = #line
    ) -> [String] {
        do {
            return try command.subcommandArguments()
        } catch {
            XCTFail("fixture command rejected: \(error)", file: file, line: line)
            return []
        }
    }
}
