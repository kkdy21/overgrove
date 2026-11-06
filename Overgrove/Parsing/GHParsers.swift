import Foundation

/// Parses `gh auth status --hostname github.com --json hosts` (parsing-spec.md §10.1).
///
/// The exit code is not used: with `--json`, gh exits 0 even when authentication is broken. Token-related fields
/// (`scopes`, `tokenSource`) are ignored.
enum GHAuthParser {
    private struct Response: Decodable {
        let hosts: [String: [Account]]
    }

    private struct Account: Decodable {
        let active: Bool?
        let state: String?
        let login: String?
    }

    static func parse(_ data: Data, host: String = "github.com") throws -> GHAuthStatus {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ParseError(parser: "GHAuthParser", offset: 0, reason: "unexpected JSON")
        }
        guard
            let account = response.hosts[host]?.first(where: { $0.active == true && $0.state == "success" }),
            let login = account.login
        else { return .notLoggedIn }
        guard isGitHubLogin(login) else {
            throw ParseError(parser: "GHAuthParser", offset: 0, reason: "invalid login")
        }
        return .loggedIn(login: login)
    }

    /// GitHub logins: 1–39 ASCII letters, digits, or hyphens.
    static func isGitHubLogin(_ login: String) -> Bool {
        let utf8 = login.utf8
        return (1...39).contains(utf8.count)
            && utf8.allSatisfy {
                ($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x7A || (0x30...0x39).contains($0) || $0 == 0x2D
            }
    }
}

/// Parses `gh issue list --json number,title,state,labels,assignees,updatedAt,url` (parsing-spec.md §10.2).
enum IssueParser {
    private struct RawIssue: Decodable {
        struct RawLabel: Decodable {
            let name: String
            let color: String?
        }

        struct RawAssignee: Decodable {
            let login: String
        }

        let number: Int
        let title: String
        let state: String
        let labels: [RawLabel]?
        let assignees: [RawAssignee]?
        let updatedAt: String
        let url: String
    }

    static func parse(_ data: Data) throws -> [Issue] {
        let raw: [RawIssue]
        do {
            raw = try JSONDecoder().decode([RawIssue].self, from: data)
        } catch {
            throw ParseError(parser: "IssueParser", offset: 0, reason: "unexpected JSON")
        }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try raw.enumerated().map { index, item in
            guard let state = Issue.State(rawValue: item.state) else {
                throw ParseError(parser: "IssueParser", offset: index, reason: "unknown state")
            }
            guard let updatedAt = plain.date(from: item.updatedAt) ?? fractional.date(from: item.updatedAt) else {
                throw ParseError(parser: "IssueParser", offset: index, reason: "invalid updatedAt")
            }
            // Only github.com links are opened from the app.
            guard item.url.hasPrefix("https://github.com/"), let url = URL(string: item.url) else {
                throw ParseError(parser: "IssueParser", offset: index, reason: "unexpected URL")
            }
            return Issue(
                number: item.number,
                title: item.title,
                state: state,
                labels: (item.labels ?? []).map { Issue.Label(name: $0.name, color: $0.color) },
                assignees: (item.assignees ?? []).map(\.login),
                updatedAt: updatedAt,
                url: url
            )
        }
    }
}
