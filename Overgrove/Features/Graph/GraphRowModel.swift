import Foundation

/// One ref pill in the graph's Refs column (art-direction.md §5.5, screens.md S-01).
struct GraphRefPill: Sendable, Equatable {
    enum Kind: Sendable, Equatable, Comparable {
        /// The focused worktree's checked-out branch: lane-color fill and `tree`.
        case focusedBranch
        /// The focused worktree when it is detached: neutral border, `tree`, folder name.
        case focusedDetached
        /// A branch another worktree has checked out: 20% fill, border, `tree`.
        case worktreeBranch
        case localBranch
        /// A detached worktree other than the focused one.
        case detachedWorktree
        /// A remote-tracking branch with no local branch of the same name on the same commit.
        case remoteBranch
        case tag
    }

    let kind: Kind
    /// Safe to show (`PathValidator.displayable`).
    let title: String
    /// A local branch merged with `origin/<same name>` on the same commit: drawn with a trailing `network` (#159).
    let hasMatchingRemote: Bool
    /// Every ref the pill stands for, one per line, escaped.
    let tooltip: String
}

/// Ref pills per commit, in display order: focused worktree → local branches → detached worktrees → remote branches →
/// tags. Only the first is drawn; the rest go into the `+n` chip (art-direction.md §5.5).
enum GraphRefDecorations {
    static func make(
        refs: RefParser.Listing, worktrees: [Worktree], focused: GitPath?
    ) -> [ObjectID: [GraphRefPill]] {
        var pills: [ObjectID: [GraphRefPill]] = [:]
        func add(_ pill: GraphRefPill, at oid: ObjectID) { pills[oid, default: []].append(pill) }

        let focusedWorktree = worktrees.first { $0.path == focused }
        let checkedOut = Dictionary(
            worktrees.compactMap { worktree in worktree.branch.map { ($0, worktree) } },
            uniquingKeysWith: { first, _ in first })
        let remotes = Dictionary(
            refs.branches.filter { if case .remote = $0.kind { $0.symbolicTarget == nil } else { false } }
                .map { ($0.fullName, $0) },
            uniquingKeysWith: { first, _ in first })
        var mergedRemotes: Set<String> = []

        for branch in refs.branches where branch.kind == .local {
            let short = branch.shortName
            let originName = "refs/remotes/origin/\(short)"
            let matchingRemote = remotes[originName].flatMap { $0.target == branch.target ? $0 : nil }
            if matchingRemote != nil { mergedRemotes.insert(originName) }
            let kind: GraphRefPill.Kind =
                if let worktree = checkedOut[branch.fullName] {
                    worktree.path == focused ? .focusedBranch : .worktreeBranch
                } else {
                    .localBranch
                }
            let names = [branch.fullName] + (matchingRemote.map { [$0.fullName] } ?? [])
            add(
                GraphRefPill(
                    kind: kind, title: PathValidator.displayable(short), hasMatchingRemote: matchingRemote != nil,
                    tooltip: names.map(PathValidator.displayable).joined(separator: "\n")),
                at: branch.target)
        }
        for worktree in worktrees where worktree.branch == nil && !worktree.isBare {
            guard let head = worktree.head else { continue }
            let folder = (worktree.path.display as NSString).lastPathComponent
            add(
                GraphRefPill(
                    kind: worktree.path == focusedWorktree?.path ? .focusedDetached : .detachedWorktree,
                    title: PathValidator.displayable(folder), hasMatchingRemote: false,
                    tooltip: PathValidator.displayable(worktree.path.display)),
                at: head)
        }
        for (name, branch) in remotes where !mergedRemotes.contains(name) {
            add(
                GraphRefPill(
                    kind: .remoteBranch, title: PathValidator.displayable(branch.shortName), hasMatchingRemote: false,
                    tooltip: PathValidator.displayable(name)),
                at: branch.target)
        }
        for tag in refs.tags {
            add(
                GraphRefPill(
                    kind: .tag, title: PathValidator.displayable(tag.shortName), hasMatchingRemote: false,
                    tooltip: PathValidator.displayable(tag.fullName)),
                at: tag.commit)
        }
        return pills.mapValues { list in
            list.sorted { ($0.kind, $0.title) < ($1.kind, $1.title) }
        }
    }
}

/// The WIP row above the focused worktree's HEAD (screens.md S-01): shown only when it has uncommitted changes.
struct GraphWipRow: Sendable, Equatable {
    let folderName: String
    /// `⚠ 2 conflicted · WIP 3 staged · 2 unstaged · 1 untracked`.
    let summary: String
    /// The commit the dashed line runs to; `nil` on an unborn branch.
    let head: ObjectID?
    /// `Uncommitted changes in api-wt: 3 staged, 2 unstaged` (interaction.md §6.1).
    var accessibilityLabel = ""

    static func make(worktree: Worktree, state: WorkingState) -> GraphWipRow? {
        guard !state.isClean else { return nil }
        var parts: [String] = []
        if !state.staged.isEmpty { parts.append("\(state.staged.count) staged") }
        if !state.unstaged.isEmpty { parts.append("\(state.unstaged.count) unstaged") }
        if !state.untracked.isEmpty { parts.append("\(state.untracked.count) untracked") }
        var summary = "WIP" + (parts.isEmpty ? "" : " " + parts.joined(separator: " · "))
        if !state.conflicted.isEmpty { summary = "⚠ \(state.conflicted.count) conflicted · " + summary }
        let folder = (worktree.path.display as NSString).lastPathComponent
        let folderName = PathValidator.displayable(folder)
        return GraphWipRow(
            folderName: folderName, summary: summary, head: state.headCommit ?? worktree.head,
            accessibilityLabel: GraphRowAccessibility.wipLabel(folderName: folderName, state: state))
    }
}

/// The text columns of one commit row.
struct GraphCommitText: Sendable, Equatable {
    let subject: String
    let isAIAssisted: Bool
    let author: String
    let initials: String
    let avatarIndex: Int
    let date: String
    /// ISO 8601 in the local time zone, for the Date tooltip.
    let absoluteDate: String
    let shortSHA: String

    init(_ commit: CommitNode, now: Date, rule: AIAgentRule = .builtIn) {
        subject = PathValidator.displayable(commit.subject)
        isAIAssisted = rule.isAIAssisted(commit)
        author = PathValidator.displayable(commit.authorName)
        initials = AuthorAvatar.initials(name: commit.authorName)
        avatarIndex = AuthorAvatar.colorIndex(email: commit.authorEmail)
        date = Self.compact(commit.authorDate, now: now)
        absoluteDate = Self.iso.string(from: commit.authorDate)
        shortSHA = commit.oid.short
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    /// `now`, `5m`, `2h`, `3d`, `4w`, `5mo`, `2y` (screens.md S-01 Date column).
    static func compact(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        case ..<(7 * 86_400): return "\(seconds / 86_400)d"
        case ..<(30 * 86_400): return "\(seconds / (7 * 86_400))w"
        case ..<(365 * 86_400): return "\(seconds / (30 * 86_400))mo"
        default: return "\(seconds / (365 * 86_400))y"
        }
    }
}

/// What VoiceOver reads for a graph row (interaction.md §6.1, #75). The lane drawing is hidden; everything it shows
/// that matters (refs, HEAD, merge) is read as words.
enum GraphRowAccessibility {
    /// `Commit a1b2c3d, feat: add status parser, Ko, 2 hours ago, branches feat/12 and origin/feat/12, HEAD of
    /// worktree feat/12, merge commit, 2 parents`.
    static func label(
        commit: CommitNode, text: GraphCommitText, pills: [GraphRefPill], isHead: Bool, linkedIssues: [Int] = [],
        isHighlighted: Bool = false, now: Date
    ) -> String {
        var parts = ["Commit \(text.shortSHA)", text.subject]
        if text.isAIAssisted { parts.append("AI-assisted") }
        parts.append(text.author)
        parts.append(relative(commit.authorDate, now: now))
        parts += refs(pills)
        if isHead {
            let focused = pills.first { $0.kind == .focusedBranch || $0.kind == .focusedDetached }
            parts.append(focused.map { "HEAD of worktree \($0.title)" } ?? "HEAD of the focused worktree")
        }
        if commit.isMerge { parts.append("merge commit, \(commit.parents.count) parents") }
        if !linkedIssues.isEmpty { parts.append("issue " + linkedIssues.map(String.init).joined(separator: ", ")) }
        if isHighlighted { parts.append("linked to the selected issue") }
        return parts.joined(separator: ", ")
    }

    /// The absolute date, read after a pause (`3 November 2026 at 14:22`).
    static func hint(_ commit: CommitNode) -> String {
        absolute.string(from: commit.authorDate)
    }

    /// `Uncommitted changes in api-wt: 3 staged, 2 unstaged, 1 untracked, 1 conflicted`.
    static func wipLabel(folderName: String, state: WorkingState) -> String {
        let counts = [
            (state.staged.count, "staged"), (state.unstaged.count, "unstaged"),
            (state.untracked.count, "untracked"), (state.conflicted.count, "conflicted"),
        ]
        .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return "Uncommitted changes in \(folderName): " + counts.joined(separator: ", ")
    }

    /// `branches feat/12 and origin/feat/12`, `tag v1.0`, `detached worktree review`.
    static func refs(_ pills: [GraphRefPill]) -> [String] {
        var branches: [String] = []
        var tags: [String] = []
        var detached: [String] = []
        for pill in pills {
            switch pill.kind {
            case .focusedBranch, .worktreeBranch, .localBranch:
                branches.append(pill.title)
                if pill.hasMatchingRemote { branches.append("origin/" + pill.title) }
            case .remoteBranch: branches.append(pill.title)
            case .tag: tags.append(pill.title)
            case .focusedDetached, .detachedWorktree: detached.append(pill.title)
            }
        }
        return [
            list(branches, one: "branch", many: "branches"), list(tags, one: "tag", many: "tags"),
            list(detached, one: "detached worktree", many: "detached worktrees"),
        ].compactMap { $0 }
    }

    private static func list(_ names: [String], one: String, many: String) -> String? {
        guard let last = names.last else { return nil }
        let joined = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
        return "\(names.count == 1 ? one : many) \(joined)"
    }

    /// `2 hours ago`, spelled out for speech.
    static func relative(_ date: Date, now: Date) -> String {
        relativeFormatter.localizedString(for: min(date, now), relativeTo: now)
    }

    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let absolute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()
}
