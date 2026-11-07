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
        /// Links past the per-kind limit, counted but not kept (a remote can push thousands of `feat/1-*` refs).
        var hiddenCount = 0
    }

    /// How an issue row shows its link (screens.md S-06): `tree` for a worktree, `arrow.triangle.branch` for a local
    /// branch only. Remote branches alone do not count (information-architecture.md §4.2).
    enum Kind: Equatable {
        case worktree
        case branch
    }

    /// Worktrees, local branches, and remote branches kept per issue, each (security review of #82, T15).
    static let limitPerKind = 10

    static let empty = IssueLinkIndex(byIssue: [:], kinds: [:])

    private let byIssue: [Int: Links]
    private let kinds: [Int: Kind]

    private init(byIssue: [Int: Links], kinds: [Int: Kind]) {
        self.byIssue = byIssue
        self.kinds = kinds
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
        // Longest configured remote first, so `team/a` wins over `team` (as in `BranchListModel`).
        let configured = listing.remoteNames.sorted { $0.utf8.count > $1.utf8.count }
        for branch in listing.refs?.branches ?? [] where branch.symbolicTarget == nil {
            let isRemote = branch.kind != .local
            // A remote branch's first part is the remote name; the branch rule then reads the rest.
            let name = isRemote ? Self.dropRemote(branch.shortName, configured: configured) : branch.shortName
            guard let number = IssueRefExtractor.issueNumber(inBranch: name) else { continue }
            byIssue[number, default: Links()].branches.append(
                BranchLink(
                    fullName: branch.fullName, title: PathValidator.displayable(branch.shortName),
                    target: branch.target, isRemote: isRemote))
        }
        kinds = byIssue.compactMapValues { links in
            if !links.worktrees.isEmpty { return .worktree }
            return links.branches.contains { !$0.isRemote } ? .branch : nil
        }
        self.byIssue = byIssue.mapValues(Self.limited)
    }

    func links(_ number: Int) -> Links { byIssue[number] ?? Links() }

    func kind(_ number: Int) -> Kind? { kinds[number] }

    /// Sorted by name (local branches before remote ones), at most `limitPerKind` of each kind.
    private static func limited(_ links: Links) -> Links {
        let worktrees = links.worktrees.sorted { $0.title < $1.title }
        let local = links.branches.filter { !$0.isRemote }.sorted { $0.title < $1.title }
        let remote = links.branches.filter(\.isRemote).sorted { $0.title < $1.title }
        let keptWorktrees = Array(worktrees.prefix(limitPerKind))
        let keptBranches = Array(local.prefix(limitPerKind)) + Array(remote.prefix(limitPerKind))
        let hidden = links.worktrees.count + links.branches.count - keptWorktrees.count - keptBranches.count
        return Links(worktrees: keptWorktrees, branches: keptBranches, hiddenCount: hidden)
    }

    /// `origin/feat/12-x` → `feat/12-x`: a configured remote's name (which may contain `/`, or look like `99-x`) is
    /// cut byte-exactly; otherwise the first segment.
    private static func dropRemote(_ shortName: String, configured: [String]) -> String {
        if let remote = configured.first(where: { shortName.utf8.starts(with: ($0 + "/").utf8) }) {
            return String(decoding: shortName.utf8.dropFirst(remote.utf8.count + 1), as: UTF8.self)
        }
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

    static let limit = 5

    /// Only this much of a subject is scanned: git does not cut subjects, and a reference past a screenful is not one
    /// anybody reads (security review of #82, T15).
    static let subjectScanLimit = 1_024

    /// The newest `limit` commits whose subject names `number` (`#n`, or `owner/repo#n` for `repository`). The graph
    /// lists newest first, so the scan stops at the limit.
    static func latest(
        _ limit: Int = limit, linkedTo number: Int, in commits: some Collection<CommitNode>, repository: String?
    ) -> [CommitLink] {
        var found: [CommitLink] = []
        for commit in commits where found.count < limit {
            guard issueNumbers(in: commit.subject, repository: repository).contains(number) else { continue }
            found.append(
                CommitLink(
                    id: commit.oid, shortSHA: commit.oid.short, subject: PathValidator.displayable(commit.subject)))
        }
        return found
    }

    /// Subject references within the first `subjectScanLimit` characters.
    static func issueNumbers(in subject: String, repository: String?) -> [Int] {
        IssueRefExtractor.issueNumbers(inSubject: String(subject.prefix(subjectScanLimit)), repository: repository)
    }
}

/// What issue badges need to draw and act (#82): numbers in the fetched list are links, others are grey.
struct IssueBadgeContext: Equatable {
    var known: Set<Int> = []
    /// `OWNER/NAME` the issues come from, for `owner/repo#n` in commit subjects.
    var repository: String?
    var select: (Int) -> Void = { _ in }

    func isKnown(_ number: Int) -> Bool { known.contains(number) }

    /// The closure is not compared: a new one each render must not redraw every badge.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.known == rhs.known && lhs.repository == rhs.repository
    }
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
