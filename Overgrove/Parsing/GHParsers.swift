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

/// Parses `gh pr list --json number,title,state,isDraft,isCrossRepository,headRefName,headRepositoryOwner,`
/// `headRepository,baseRefName,reviewDecision,mergedAt,updatedAt,url` (parsing-spec.md §10.3, ADR-0023 §3).
///
/// Anyone can open a pull request on a public repository, so one odd entry must not hide the others: only output that
/// is not a JSON array fails. An entry without a usable `number`, `state`, or `url` is dropped; an entry without a head
/// repository or owner (a deleted fork) is kept with `head == nil` and is never linked to a branch.
enum PullRequestParser {
    private struct Owner: Decodable {
        let login: String
    }

    private struct Repository: Decodable {
        let name: String
    }

    private struct Entry: Decodable {
        let value: PullRequest?

        private enum Keys: String, CodingKey {
            case number, title, state, isDraft, headRefName, headRepositoryOwner, headRepository, baseRefName
            case reviewDecision, updatedAt, url
        }

        init(from decoder: Decoder) {
            value = try? Self.pullRequest(decoder)
        }

        private static func pullRequest(_ decoder: Decoder) throws -> PullRequest? {
            let item = try decoder.container(keyedBy: Keys.self)
            let number = try item.decode(Int.self, forKey: .number)
            let urlText = try item.decode(String.self, forKey: .url)
            guard number > 0, urlText.hasPrefix("https://github.com/"), let url = URL(string: urlText) else {
                return nil
            }
            let state: PullRequest.State =
                switch try item.decode(String.self, forKey: .state) {
                case "OPEN": .open
                case "CLOSED": .closed
                case "MERGED": .merged
                default: .unknown
                }
            let review: PullRequest.ReviewDecision =
                switch (try? item.decodeIfPresent(String.self, forKey: .reviewDecision)) ?? nil {
                case "APPROVED": .approved
                case "CHANGES_REQUESTED": .changesRequested
                case "REVIEW_REQUIRED": .reviewRequired
                default: .none
                }
            let owner = (try? item.decodeIfPresent(Owner.self, forKey: .headRepositoryOwner))??.login
            let name = (try? item.decodeIfPresent(Repository.self, forKey: .headRepository))??.name
            let branch = (try? item.decodeIfPresent(String.self, forKey: .headRefName)) ?? nil
            let head: PullRequest.Head? =
                if let owner, let name, let branch, !owner.isEmpty, !name.isEmpty, !branch.isEmpty {
                    PullRequest.Head(owner: owner, name: name, branch: branch)
                } else {
                    nil
                }
            let updated = (try? item.decodeIfPresent(String.self, forKey: .updatedAt)) ?? nil
            return PullRequest(
                number: number,
                title: ((try? item.decodeIfPresent(String.self, forKey: .title)) ?? nil) ?? "",
                state: state,
                isDraft: ((try? item.decodeIfPresent(Bool.self, forKey: .isDraft)) ?? nil) ?? false,
                head: head,
                baseRefName: ((try? item.decodeIfPresent(String.self, forKey: .baseRefName)) ?? nil) ?? "",
                reviewDecision: review,
                updatedAt: updated.flatMap(GHDate.parse),
                url: url
            )
        }
    }

    /// The most `GHCommand.prList` asks for; anything past it is ignored.
    static let limit = 200

    static func parse(_ data: Data) throws -> [PullRequest] {
        do {
            return try JSONDecoder().decode([Entry].self, from: data).prefix(limit).compactMap(\.value)
        } catch {
            throw ParseError(parser: "PullRequestParser", offset: 0, reason: "unexpected JSON")
        }
    }
}

/// gh's ISO 8601 times, with or without fractional seconds.
enum GHDate {
    static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
