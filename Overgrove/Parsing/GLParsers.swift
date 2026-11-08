import Foundation

/// One host from `glab auth status --hostname H --output json` (ADR-0026 §2–§4). Only these fields are read: no token
/// source, endpoints, or warnings, and glab never puts the token itself in this JSON (`--show-token` has no case).
struct GLHostStatus: Sendable, Equatable {
    let host: String
    /// The account glab confirmed; `nil` unless the check succeeded.
    let user: String?
    /// `state == "success"` with a user name.
    var isLoggedIn: Bool { user != nil }
}

/// Parses `glab auth status --hostname H --output json`: `{"hosts":[{"host":…,"state":"success"|"error","user":…}]}`
/// (glab 1.128.0, internal/commands/auth/status). A host whose state is not `success`, or that has no user, is not
/// logged in. Anything that is not that object fails.
enum GLAuthParser {
    private struct Response: Decodable {
        struct Host: Decodable {
            let host: String?
            let state: String?
            let user: String?
        }
        let hosts: [Host]
    }

    static func parse(_ data: Data) throws -> [GLHostStatus] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ParseError(parser: "GLAuthParser", offset: 0, reason: "unexpected JSON")
        }
        return response.hosts.compactMap { host in
            guard let name = host.host, !name.isEmpty else { return nil }
            let user = host.state == "success" ? host.user.flatMap { $0.isEmpty ? nil : $0 } : nil
            return GLHostStatus(host: name, user: user)
        }
    }
}

/// Parses `glab issue list --output json` (GitLab API issue objects, glab 1.128.0) into `Issue` (ADR-0026 §4).
///
/// Anyone who can open an issue writes part of this output, so one odd entry drops only itself: only output that is not
/// a JSON array fails. An entry without a usable `iid`, `title`, `state`, or https `web_url` is dropped. The body
/// (`description`) is never read. At most `maximumIssues` entries are kept; titles, labels, and label names are cut.
enum GLIssueParser {
    static let maximumIssues = 200
    static let maximumTitle = 1_000
    static let maximumLabels = 50
    static let maximumLabelName = 100

    private struct Entry: Decodable {
        let value: Issue?

        private enum Keys: String, CodingKey {
            case iid, title, state, labels, assignees
            case updatedAt = "updated_at"
            case webURL = "web_url"
        }

        private struct Assignee: Decodable {
            let username: String?
        }

        init(from decoder: Decoder) {
            value = try? Self.issue(decoder)
        }

        private static func issue(_ decoder: Decoder) throws -> Issue? {
            let item = try decoder.container(keyedBy: Keys.self)
            let number = try item.decode(Int.self, forKey: .iid)
            let title = try item.decode(String.self, forKey: .title)
            let urlText = try item.decode(String.self, forKey: .webURL)
            let state: Issue.State
            switch try item.decode(String.self, forKey: .state) {
            case "opened": state = .open
            case "closed": state = .closed
            default: return nil
            }
            guard number > 0, urlText.hasPrefix("https://"), let url = URL(string: urlText),
                let updated = (try? item.decodeIfPresent(String.self, forKey: .updatedAt)) ?? nil,
                let updatedAt = GHDate.parse(updated)
            else { return nil }
            let labels = ((try? item.decodeIfPresent([String].self, forKey: .labels)) ?? nil) ?? []
            let assignees = ((try? item.decodeIfPresent([Assignee].self, forKey: .assignees)) ?? nil) ?? []
            return Issue(
                number: number,
                title: String(title.prefix(GLIssueParser.maximumTitle)),
                state: state,
                labels: labels.prefix(GLIssueParser.maximumLabels).map {
                    Issue.Label(name: String($0.prefix(GLIssueParser.maximumLabelName)), color: nil)
                },
                assignees: assignees.compactMap(\.username).filter { !$0.isEmpty },
                updatedAt: updatedAt,
                url: url
            )
        }
    }

    static func parse(_ data: Data) throws -> [Issue] {
        do {
            return try JSONDecoder().decode([Entry].self, from: data).lazy.compactMap(\.value).prefix(maximumIssues)
                .map { $0 }
        } catch {
            throw ParseError(parser: "GLIssueParser", offset: 0, reason: "unexpected JSON")
        }
    }
}
