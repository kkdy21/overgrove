import XCTest

@testable import Overgrove

/// AI co-author detection for the graph badge (#160).
final class AIAgentRuleTests: XCTestCase {
    private let rule = AIAgentRule.builtIn

    func testKnownAgentAddressesMatch() {
        for coAuthor in [
            "Claude Opus 5.5 <noreply@anthropic.com>",
            "Claude <NoReply@Anthropic.com>",
            "Cursor Agent <cursoragent@cursor.com>",
            "aider (some-model) <noreply@aider.chat>",
            "Copilot <175728472+Copilot@users.noreply.github.com>",
            "devin-ai-integration[bot] <158243242+devin-ai-integration[bot]@users.noreply.github.com>",
        ] {
            XCTAssertTrue(rule.isAgent(coAuthor), coAuthor)
        }
    }

    func testPeopleAndLookalikesDoNotMatch() {
        for coAuthor in [
            "Claude Monet <claude@example.com>",  // a person named Claude
            "Cursor <cursor@example.com>",
            "Alice <alice@example.com>",
            "noreply@anthropic.com",  // no angle brackets: not a `Name <email>` value
            "Evil <noreply@anthropic.com.evil.example>",
            "Evil <x-noreply@anthropic.com>",
            "Copilot <copilot@users.noreply.github.com>",  // not a numbered bot account
            "Someone <>",
            "",
        ] {
            XCTAssertFalse(rule.isAgent(coAuthor), coAuthor)
        }
    }

    func testEmailIsTakenFromTheLastAngleBrackets() {
        XCTAssertEqual(AIAgentRule.email(in: "A <b> Name <noreply@anthropic.com>"), "noreply@anthropic.com")
        XCTAssertEqual(AIAgentRule.email(in: "Name < Spaced@Example.com >"), "spaced@example.com")
        XCTAssertNil(AIAgentRule.email(in: "Name <unclosed"))
    }

    func testRuleCanBeExtendedFromSettings() {
        let extended = rule.adding(emails: ["Bot@Company.example"], emailSuffixes: ["@agents.company.example"])
        XCTAssertTrue(extended.isAgent("In-house <bot@company.example>"))
        XCTAssertTrue(extended.isAgent("Fleet <42@agents.company.example>"))
        XCTAssertTrue(extended.isAgent("Claude <noreply@anthropic.com>"), "built-in entries stay")
        XCTAssertFalse(rule.isAgent("In-house <bot@company.example>"), "the original rule is unchanged")
    }

    func testCommitIsAIAssistedWhenAnyCoAuthorIsAnAgent() throws {
        let oid = try XCTUnwrap(ObjectID(String(repeating: "a", count: 40)))
        let commit = { (coAuthors: [String]) in
            CommitNode(
                oid: oid, parents: [], authorName: "t", authorEmail: "t@example.com",
                authorDate: Date(timeIntervalSince1970: 0), subject: "s", coAuthors: coAuthors)
        }
        XCTAssertFalse(rule.isAIAssisted(commit([])))
        XCTAssertFalse(rule.isAIAssisted(commit(["Alice <alice@example.com>"])))
        XCTAssertTrue(rule.isAIAssisted(commit(["Alice <alice@example.com>", "Claude <noreply@anthropic.com>"])))
    }
}
