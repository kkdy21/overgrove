import SwiftUI

/// Worktrees and branches linked to issue numbers by their names (parsing-spec.md §11.3, information-architecture.md
/// §3.3). Built once per listing; pure, so it is unit tested without views.
struct IssueLinkIndex: Equatable {
    struct WorktreeLink: Equatable {
        let path: GitPath
        /// The branch's short name, escaped.
        let title: String
    }

    struct BranchLink: Equatable {
        let fullName: String
        /// `feat/12-x`, `origin/feat/12-x`, escaped.
        let title: String
        let target: ObjectID
        let isRemote: Bool
    }

    struct Links: Equatable {
        var worktrees: [WorktreeLink] = []
        var branches: [BranchLink] = []
    }

    /// How an issue row shows its link (screens.md S-06): `tree` for a worktree, `arrow.triangle.branch` for a local
    /// branch only. Remote branches alone do not count (information-architecture.md §4.2).
    enum Kind: Equatable {
        case worktree
        case branch
    }

    static let empty = IssueLinkIndex(byIssue: [:])

    private let byIssue: [Int: Links]

    private init(byIssue: [Int: Links]) {
        self.byIssue = byIssue
    }

    init(listing: WorktreeListing) {
        var byIssue: [Int: Links] = [:]
        for entry in listing.entries where !entry.worktree.isBare {
            guard let branch = entry.worktree.branch, let number = IssueRefExtractor.issueNumber(inBranch: branch)
            else { continue }
            byIssue[number, default: Links()].worktrees.append(
                WorktreeLink(
                    path: entry.worktree.path,
                    title: PathValidator.displayable(entry.worktree.branchShortName ?? branch)))
        }
        for branch in listing.refs?.branches ?? [] where branch.symbolicTarget == nil {
            let isRemote = branch.kind != .local
            // A remote branch's first segment is the remote name; the branch rule then reads the rest.
            let name = isRemote ? Self.dropRemote(branch.shortName) : branch.shortName
            guard let number = IssueRefExtractor.issueNumber(inBranch: name) else { continue }
            byIssue[number, default: Links()].branches.append(
                BranchLink(
                    fullName: branch.fullName, title: PathValidator.displayable(branch.shortName),
                    target: branch.target, isRemote: isRemote))
        }
        self.byIssue = byIssue.mapValues { links in
            var links = links
            // Local before remote, then by name.
            links.branches.sort { ($0.isRemote ? 1 : 0, $0.title) < ($1.isRemote ? 1 : 0, $1.title) }
            links.worktrees.sort { $0.title < $1.title }
            return links
        }
    }

    func links(_ number: Int) -> Links { byIssue[number] ?? Links() }

    func kind(_ number: Int) -> Kind? {
        guard let links = byIssue[number] else { return nil }
        if !links.worktrees.isEmpty { return .worktree }
        return links.branches.contains { !$0.isRemote } ? .branch : nil
    }

    /// `origin/feat/12-x` → `feat/12-x`. Remote names may contain `/`, but then the branch rule still finds the
    /// first `12-` segment.
    private static func dropRemote(_ shortName: String) -> String {
        guard let slash = shortName.firstIndex(of: "/") else { return shortName }
        return String(shortName[shortName.index(after: slash)...])
    }
}

/// A commit in S-06's LINKED card: one whose subject references the issue (parsing-spec.md §11.3).
struct CommitLink: Equatable, Identifiable {
    let id: ObjectID
    let shortSHA: String
    /// Escaped.
    let subject: String

    /// The newest `limit` loaded commits whose subject names `number` (`#n`, or `owner/repo#n` for `repository`).
    /// The graph lists newest first, so the scan stops at the limit.
    static func latest(
        _ limit: Int = 5, linkedTo number: Int, in commits: [CommitNode], repository: String?
    ) -> [CommitLink] {
        var found: [CommitLink] = []
        for commit in commits where found.count < limit {
            guard IssueRefExtractor.issueNumbers(inSubject: commit.subject, repository: repository).contains(number)
            else { continue }
            found.append(
                CommitLink(
                    id: commit.oid, shortSHA: commit.oid.short, subject: PathValidator.displayable(commit.subject)))
        }
        return found
    }
}

/// What issue badges need to draw and act (#82): numbers in the fetched list are links, others are grey.
struct IssueBadgeContext {
    var known: Set<Int> = []
    /// `OWNER/NAME` the issues come from, for `owner/repo#n` in commit subjects.
    var repository: String?
    var select: (Int) -> Void = { _ in }

    func isKnown(_ number: Int) -> Bool { known.contains(number) }
}

extension EnvironmentValues {
    @Entry var issueBadges = IssueBadgeContext()
}

extension View {
    /// The row hides its children from VoiceOver, so a linked issue badge becomes a named action on the row.
    func issueBadgeAction(_ number: Int?) -> some View {
        modifier(IssueBadgeAction(number: number))
    }
}

private struct IssueBadgeAction: ViewModifier {
    let number: Int?
    @Environment(\.issueBadges) private var context

    func body(content: Content) -> some View {
        if let number, context.isKnown(number) {
            content.accessibilityAction(named: "Show issue #\(number)") { context.select(number) }
        } else {
            content
        }
    }
}

/// The `#12` pill (information-architecture.md §4.3, priority 6): a `text.secondary` border and a link to S-06 when
/// the number is in the fetched list, grey and inert otherwise (parsing-spec.md §11.3).
struct IssueNumberBadge: View {
    let number: Int
    @Environment(\.issueBadges) private var context

    var body: some View {
        let isKnown = context.isKnown(number)
        let label = Text("#\(number)")
            .font(Tokens.Font.pill)
            .foregroundStyle(isKnown ? Tokens.Color.textSecondary : Tokens.Color.textTertiary)
            .padding(.horizontal, Tokens.Spacing.xs)
            .overlay(
                Capsule().strokeBorder(
                    isKnown ? Tokens.Color.textSecondary : Tokens.Color.borderSeparator, lineWidth: 1)
            )
            .fixedSize()
        if isKnown {
            Button {
                context.select(number)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help("Show issue #\(number)")
            .accessibilityLabel("Issue \(number)")
        } else {
            label
                .help("#\(number) is not in the open issue list")
                .accessibilityLabel("Issue \(number), not in the open issue list")
        }
    }
}
