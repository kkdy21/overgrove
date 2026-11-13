import Foundation

/// Overgrove's own reasons for stopping queries, refusing a fetch, or not inspecting a worktree (#495).
///
/// Each reason is English text that Copy Report and the tests use unchanged (the report value). `display(_:)` gives
/// the text for the screen in the user's language (the display value). Reasons travel as the report value, so the
/// screen converts at the point it shows one; text that is not one of these reasons is returned as is.
enum SafetyReason {
    // MARK: Queries stopped (`RepoSecurityReport.blockingReason`)

    static let truncatedListing =
        "The configuration listing was truncated, so it could not be inspected completely."
    static let keyContainsEquals = "A configuration key contains \"=\" and cannot be overridden safely."
    static let keyNotUTF8 = "A configuration key is not valid UTF-8 and cannot be overridden safely."
    static let unsafeFilterDriver = "A filter driver name contains characters that cannot be neutralized safely."
    static let unneutralizedHooks = "This repository defines hooks in its settings that Overgrove cannot turn off."

    static func tooManyFilterDrivers(_ count: Int, limit: Int) -> String {
        "This repository defines \(count) filter drivers, more than Overgrove can neutralize (\(limit))."
    }

    // MARK: Fetch disabled

    static let ownTLSFiles = "This repository sets its own TLS certificate files; fetching is disabled."
    static let pinnedHosts = "This repository pins host names to addresses; fetching is disabled."
    static let ownRefStorage = "This repository keeps its references in a location it chose; fetching is disabled."
    static let tooManyFetchOverrides =
        "This repository sets TLS or proxy options for too many URLs to override; fetching is disabled."
    static let partialClone = "This repository is a partial clone; Overgrove never downloads missing objects."
    static let partialCloneNeedsNewerGit =
        "This repository is a partial clone. Fetching it safely needs git \(GitEnvironment.lazyFetchControlVersion) "
        + "or later; fetching is disabled."
    static let passwordInURL =
        "This remote's URL contains a password, so Overgrove does not fetch it: git would send the password and "
        + "could save it to your credential helper. Remove it from the URL and use a credential helper instead."
    static let nonBuiltInRemote =
        "This remote does not use a built-in transport (https, ssh, git, or a local path); fetching it is disabled."
    static let untrustedLocalRemote =
        "This repository is marked untrusted, so Overgrove does not fetch remotes on this Mac (local paths and "
        + "file:// URLs): fetching runs git in the other repository with its own settings. Mark the repository "
        + "trusted to fetch them."
    static let localRemoteNeedsNewerGit =
        "This git version cannot fetch remotes on this Mac (local paths and file:// URLs) safely. Overgrove needs git "
        + "\(GitEnvironment.lazyFetchControlVersion) or later to fetch them."

    // MARK: Worktree not inspected

    static let worktreeFolderMissing = "The worktree folder could not be found."
    static let notInspected = "This worktree's configuration was not inspected when the list loaded."
    static let noLongerMatches = "This folder no longer matches the repository, so it was not inspected."

    // MARK: Display

    /// The screen text for `report`: localized when it is one of these reasons, otherwise `report` unchanged.
    static func display(_ report: String) -> String {
        let version = "\(GitEnvironment.lazyFetchControlVersion)"
        switch report {
        case truncatedListing:
            return String(
                localized: "The configuration listing was truncated, so it could not be inspected completely.")
        case keyContainsEquals:
            return String(localized: "A configuration key contains \"=\" and cannot be overridden safely.")
        case keyNotUTF8:
            return String(localized: "A configuration key is not valid UTF-8 and cannot be overridden safely.")
        case unsafeFilterDriver:
            return String(localized: "A filter driver name contains characters that cannot be neutralized safely.")
        case unneutralizedHooks:
            return String(localized: "This repository defines hooks in its settings that Overgrove cannot turn off.")
        case ownTLSFiles:
            return String(localized: "This repository sets its own TLS certificate files; fetching is disabled.")
        case pinnedHosts:
            return String(localized: "This repository pins host names to addresses; fetching is disabled.")
        case ownRefStorage:
            return String(
                localized: "This repository keeps its references in a location it chose; fetching is disabled.")
        case tooManyFetchOverrides:
            return String(
                localized:
                    "This repository sets TLS or proxy options for too many URLs to override; fetching is disabled.")
        case partialClone:
            return String(localized: "This repository is a partial clone; Overgrove never downloads missing objects.")
        case partialCloneNeedsNewerGit:
            return String(
                localized:
                    "This repository is a partial clone. Fetching it safely needs git \(version) or later; fetching is disabled."
            )
        case passwordInURL:
            return String(
                localized:
                    "This remote's URL contains a password, so Overgrove does not fetch it: git would send the password and could save it to your credential helper. Remove it from the URL and use a credential helper instead."
            )
        case nonBuiltInRemote:
            return String(
                localized:
                    "This remote does not use a built-in transport (https, ssh, git, or a local path); fetching it is disabled."
            )
        case untrustedLocalRemote:
            return String(
                localized:
                    "This repository is marked untrusted, so Overgrove does not fetch remotes on this Mac (local paths and file:// URLs): fetching runs git in the other repository with its own settings. Mark the repository trusted to fetch them."
            )
        case localRemoteNeedsNewerGit:
            return String(
                localized:
                    "This git version cannot fetch remotes on this Mac (local paths and file:// URLs) safely. Overgrove needs git \(version) or later to fetch them."
            )
        case worktreeFolderMissing:
            return String(localized: "The worktree folder could not be found.")
        case notInspected:
            return String(localized: "This worktree's configuration was not inspected when the list loaded.")
        case noLongerMatches:
            return String(localized: "This folder no longer matches the repository, so it was not inspected.")
        default:
            return filterDriverCount(report).map {
                String(
                    localized:
                        "This repository defines \($0.count) filter drivers, more than Overgrove can neutralize (\($0.limit))."
                )
            } ?? report
        }
    }

    /// The numbers in a `tooManyFilterDrivers` reason, read back only when the whole text matches it.
    private static func filterDriverCount(_ report: String) -> (count: Int, limit: Int)? {
        let prefix = "This repository defines "
        let middle = " filter drivers, more than Overgrove can neutralize ("
        let suffix = ")."
        guard report.hasPrefix(prefix), report.hasSuffix(suffix) else { return nil }
        let body = report.dropFirst(prefix.count).dropLast(suffix.count)
        guard let range = body.range(of: middle),
            let count = Int(body[..<range.lowerBound]), let limit = Int(body[range.upperBound...]),
            tooManyFilterDrivers(count, limit: limit) == report
        else { return nil }
        return (count, limit)
    }
}
