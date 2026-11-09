import Foundation

/// One account from `gt auth status --json host,user,credential_available` (ADR-0026 §2–§4). Only these fields are
/// requested and read; gt never puts a token in this output.
struct GTAccount: Sendable, Equatable {
    /// The instance URL as gt printed it; `GiteaInstance` validates it before use.
    let host: String
    let user: String?
    let credentialAvailable: Bool
}

/// Parses `gt auth status --json host,user,credential_available`: a JSON array of objects (gt 1.1.0; `[]` with no
/// account, measured). An entry without a host is dropped; `credential_available` counts only when it is `true`.
/// Anything that is not an array fails.
enum GTAuthParser {
    private struct Entry: Decodable {
        let value: GTAccount?

        private enum Keys: String, CodingKey {
            case host, user
            case credentialAvailable = "credential_available"
        }

        init(from decoder: Decoder) {
            guard let item = try? decoder.container(keyedBy: Keys.self),
                let host = (try? item.decodeIfPresent(String.self, forKey: .host)) ?? nil, !host.isEmpty
            else {
                value = nil
                return
            }
            let user = ((try? item.decodeIfPresent(String.self, forKey: .user)) ?? nil).flatMap {
                $0.isEmpty ? nil : $0
            }
            let available = ((try? item.decodeIfPresent(Bool.self, forKey: .credentialAvailable)) ?? nil) == true
            value = GTAccount(host: host, user: user, credentialAvailable: available)
        }
    }

    static func parse(_ data: Data) throws -> [GTAccount] {
        do {
            return try JSONDecoder().decode([Entry].self, from: data).compactMap(\.value)
        } catch {
            throw ParseError(parser: "GTAuthParser", offset: 0, reason: "unexpected JSON")
        }
    }
}

/// Parses `gt issue list --json number,title,state,labels,assignees,updated_at,url` (gt 1.1.0) into `Issue`
/// (ADR-0026 §4). `labels` are objects (`name`, `color`, …) and `assignees` are login strings.
///
/// Anyone who can open an issue writes part of this output, so one odd entry drops only itself: only output that is not
/// a JSON array fails. An entry without a usable `number`, `title`, `state`, `updated_at`, or https `url` is dropped.
/// At most `maximumIssues` entries are kept; titles, labels, label names, and assignees are cut. A label color is kept only as six
/// hex digits.
enum GTIssueParser {
    static let maximumIssues = 200
    static let maximumTitle = 1_000
    static let maximumLabels = 50
    static let maximumLabelName = 100
    static let maximumAssignees = 50

    private struct Entry: Decodable {
        let value: Issue?

        private enum Keys: String, CodingKey {
            case number, title, state, labels, assignees, url
            case updatedAt = "updated_at"
        }

        private struct Label: Decodable {
            let name: String?
            let color: String?
        }

        /// Decodes one array element without failing the array.
        private struct Lenient<T: Decodable>: Decodable {
            let value: T?
            init(from decoder: Decoder) { value = try? T(from: decoder) }
        }

        init(from decoder: Decoder) {
            value = try? Self.issue(decoder)
        }

        private static func issue(_ decoder: Decoder) throws -> Issue? {
            let item = try decoder.container(keyedBy: Keys.self)
            let number = try item.decode(Int.self, forKey: .number)
            let title = try item.decode(String.self, forKey: .title)
            let urlText = try item.decode(String.self, forKey: .url)
            let state: Issue.State
            switch try item.decode(String.self, forKey: .state) {
            case "open": state = .open
            case "closed": state = .closed
            default: return nil
            }
            guard number > 0, urlText.hasPrefix("https://"), let url = URL(string: urlText),
                let updated = (try? item.decodeIfPresent(String.self, forKey: .updatedAt)) ?? nil,
                let updatedAt = GHDate.parse(updated)
            else { return nil }
            let labels = ((try? item.decodeIfPresent([Lenient<Label>].self, forKey: .labels)) ?? nil) ?? []
            let assignees = ((try? item.decodeIfPresent([Lenient<String>].self, forKey: .assignees)) ?? nil) ?? []
            return Issue(
                number: number,
                title: String(title.prefix(GTIssueParser.maximumTitle)),
                state: state,
                labels: labels.lazy.compactMap(\.value).compactMap { label -> Issue.Label? in
                    guard let name = label.name, !name.isEmpty else { return nil }
                    return Issue.Label(
                        name: String(name.prefix(GTIssueParser.maximumLabelName)),
                        color: label.color.flatMap(GTIssueParser.hexColor))
                }.prefix(GTIssueParser.maximumLabels).map { $0 },
                assignees: Array(
                    assignees.lazy.compactMap(\.value).filter { !$0.isEmpty }.prefix(GTIssueParser.maximumAssignees)),
                updatedAt: updatedAt,
                url: url
            )
        }
    }

    /// Six hex digits, with or without a leading `#`; anything else is no color.
    static func hexColor(_ text: String) -> String? {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.utf8.count == 6,
            digits.utf8.allSatisfy({
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0)
            })
        else { return nil }
        return digits.lowercased()
    }

    static func parse(_ data: Data) throws -> [Issue] {
        do {
            return try JSONDecoder().decode([Entry].self, from: data).lazy.compactMap(\.value).prefix(maximumIssues)
                .map { $0 }
        } catch {
            throw ParseError(parser: "GTIssueParser", offset: 0, reason: "unexpected JSON")
        }
    }
}
