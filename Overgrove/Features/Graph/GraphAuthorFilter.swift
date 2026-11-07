import Foundation

/// The chip picked in the graph's author filter row (screens.md S-01 "작성자 필터 칩 줄", #255).
enum GraphAuthorSelection: Hashable, Sendable {
    /// No filter: nothing is dimmed.
    case all
    /// One author, by `GraphAuthorSummary.key(for:)`.
    case author(String)
    /// Commits with an AI agent's `Co-authored-by` trailer (`AIAgentRule`).
    case aiAssisted
}

/// One author chip: avatar, name, and how many loaded commits they wrote.
struct GraphAuthorChip: Equatable, Identifiable, Sendable {
    let key: String
    /// Escaped for display (`PathValidator.displayable`), from the newest loaded commit by this author.
    let name: String
    let initials: String
    let avatarIndex: Int
    let count: Int

    var id: String { key }
}

/// The author chips over the loaded pages. Pure and in memory like the search (#74): no git runs, and a new page
/// only tallies its own commits (security review of #74, T15).
struct GraphAuthorSummary: Equatable, Sendable {
    /// Chips beyond this fold into the `+n` menu (screens.md S-01).
    static let visibleChipLimit = 5

    /// Count descending, then name, then key, so the order is stable between pages.
    let chips: [GraphAuthorChip]
    let aiAssistedCount: Int
    /// Commits tallied so far.
    let tallied: Int

    private let tallies: [String: Tally]

    private struct Tally: Equatable, Sendable {
        let name: String
        let initials: String
        let avatarIndex: Int
        var count: Int
    }

    static let empty = GraphAuthorSummary(tallies: [:], aiAssistedCount: 0, tallied: 0)

    init(commits: [CommitNode], rule: AIAgentRule = .builtIn) {
        self = Self.empty.extended(with: commits, rule: rule)
    }

    private init(tallies: [String: Tally], aiAssistedCount: Int, tallied: Int) {
        self.tallies = tallies
        self.aiAssistedCount = aiAssistedCount
        self.tallied = tallied
        chips = tallies.map { key, tally in
            GraphAuthorChip(
                key: key, name: tally.name, initials: tally.initials, avatarIndex: tally.avatarIndex,
                count: tally.count)
        }
        .sorted { ($1.count, $0.name, $0.key) < ($0.count, $1.name, $1.key) }
    }

    /// The same history with more pages loaded: only `commits[tallied...]` are looked at.
    func extended(with commits: [CommitNode], rule: AIAgentRule = .builtIn) -> GraphAuthorSummary {
        var tallies = tallies
        var aiAssisted = aiAssistedCount
        for commit in commits[min(tallied, commits.count)...] {
            let key = Self.key(for: commit)
            if tallies[key] != nil {
                tallies[key]?.count += 1
            } else {
                // The newest commit names the author; later spellings of the same address do not rename the chip.
                tallies[key] = Tally(
                    name: PathValidator.displayable(String(commit.authorName.prefix(Self.fieldLimit))),
                    initials: AuthorAvatar.initials(name: String(commit.authorName.prefix(Self.fieldLimit))),
                    avatarIndex: AuthorAvatar.colorIndex(email: commit.authorEmail), count: 1)
            }
            if rule.isAIAssisted(commit) { aiAssisted += 1 }
        }
        return GraphAuthorSummary(tallies: tallies, aiAssistedCount: aiAssisted, tallied: max(tallied, commits.count))
    }

    var visibleChips: ArraySlice<GraphAuthorChip> { chips.prefix(Self.visibleChipLimit) }
    var overflowChips: ArraySlice<GraphAuthorChip> { chips.dropFirst(Self.visibleChipLimit) }

    /// The row is worth showing: more than one author, or AI-assisted commits to pick out.
    var hasChoices: Bool { chips.count > 1 || aiAssistedCount > 0 }

    /// Only the start of the address is read, as for the search (`GraphSearchQuery.fieldScanLimit`).
    static let fieldLimit = GraphSearchQuery.fieldScanLimit

    /// Authors are told apart by address, case-insensitively (the avatar colour uses it too). A commit without one is
    /// keyed by name.
    static func key(for commit: CommitNode) -> String {
        func normalized(_ field: String) -> String {
            field.prefix(fieldLimit).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let email = normalized(commit.authorEmail)
        return email.isEmpty ? "name:" + normalized(commit.authorName) : email
    }

    /// `Alex Kim, 8 commits` for VoiceOver.
    static func accessibilityLabel(name: String, count: Int) -> String {
        "\(name), \(count.formatted()) \(count == 1 ? "commit" : "commits")"
    }
}

/// The loaded commits a chip picks out. Rows outside the set are dimmed, not hidden, like the search (screens.md
/// S-01); with a search query both must match.
struct GraphAuthorFilterResult: Equatable, Sendable {
    let selection: GraphAuthorSelection
    let matchSet: Set<ObjectID>
    let scanned: Int

    /// `nil` for `.all`: no filter.
    init?(selection: GraphAuthorSelection, commits: [CommitNode], rule: AIAgentRule = .builtIn) {
        guard selection != .all else { return nil }
        self.init(selection: selection, previous: [], commits: commits, from: 0, rule: rule)
    }

    private init(
        selection: GraphAuthorSelection, previous: Set<ObjectID>, commits: [CommitNode], from start: Int,
        rule: AIAgentRule
    ) {
        self.selection = selection
        var set = previous
        for commit in commits[min(start, commits.count)...] where Self.matches(commit, selection, rule: rule) {
            set.insert(commit.oid)
        }
        matchSet = set
        scanned = max(start, commits.count)
    }

    /// More pages loaded: only the new commits are looked at.
    func extended(with commits: [CommitNode], rule: AIAgentRule = .builtIn) -> GraphAuthorFilterResult {
        GraphAuthorFilterResult(selection: selection, previous: matchSet, commits: commits, from: scanned, rule: rule)
    }

    static func matches(_ commit: CommitNode, _ selection: GraphAuthorSelection, rule: AIAgentRule) -> Bool {
        switch selection {
        case .all: true
        case .author(let key): GraphAuthorSummary.key(for: commit) == key
        case .aiAssisted: rule.isAIAssisted(commit)
        }
    }
}
