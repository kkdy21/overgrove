import Foundation

/// Decides whether a commit was written together with an AI coding agent, from its `Co-authored-by` trailers (#160).
///
/// The graph and commit detail show an "AI" badge for such commits. Matching is by the co-author's email only:
/// display names such as "Claude" or "Cursor" are also ordinary people's names. Agents sign with fixed addresses
/// (or a fixed GitHub noreply suffix for bot accounts), which a person would not use by accident. The badge is a
/// review hint, not a security signal: anyone can write any trailer.
///
/// The built-in list can be extended from settings with `adding(emails:emailSuffixes:)`.
struct AIAgentRule: Sendable, Hashable {
    /// Exact addresses, lowercased.
    let emails: Set<String>
    /// Address suffixes, lowercased, for agents that sign as numbered GitHub bot accounts.
    let emailSuffixes: Set<String>

    init(emails: Set<String>, emailSuffixes: Set<String>) {
        self.emails = Set(emails.map { $0.lowercased() })
        self.emailSuffixes = Set(emailSuffixes.map { $0.lowercased() })
    }

    /// Agents known to add a `Co-authored-by` trailer by default.
    static let builtIn = AIAgentRule(
        emails: [
            "noreply@anthropic.com",  // Claude Code
            "cursoragent@cursor.com",  // Cursor agent
            "noreply@aider.chat",  // aider
        ],
        emailSuffixes: [
            "+copilot@users.noreply.github.com",  // GitHub Copilot coding agent
            "+devin-ai-integration[bot]@users.noreply.github.com",  // Devin
        ]
    )

    /// A copy of this rule that also matches `emails` and `emailSuffixes` (user settings).
    func adding(emails extraEmails: Set<String> = [], emailSuffixes extraSuffixes: Set<String> = []) -> AIAgentRule {
        AIAgentRule(emails: emails.union(extraEmails), emailSuffixes: emailSuffixes.union(extraSuffixes))
    }

    /// Whether one trailer value (`Name <email>`) names a known agent.
    func isAgent(_ coAuthor: String) -> Bool {
        guard let email = Self.email(in: coAuthor) else { return false }
        return emails.contains(email) || emailSuffixes.contains { email.hasSuffix($0) }
    }

    /// Whether any co-author of `commit` is a known agent.
    func isAIAssisted(_ commit: CommitNode) -> Bool {
        commit.coAuthors.contains(where: isAgent)
    }

    /// The lowercased address in the last `<…>` of a trailer value, or `nil` when there is none.
    static func email(in coAuthor: String) -> String? {
        guard let open = coAuthor.lastIndex(of: "<"),
            let close = coAuthor[open...].firstIndex(of: ">")
        else { return nil }
        let address = coAuthor[coAuthor.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return address.isEmpty ? nil : address.lowercased()
    }
}
