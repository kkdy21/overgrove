import Foundation

/// An open S-12 (#388, screens.md S-12): two commits, their file list, and the picked file's patch.
struct CommitComparisonSession: Equatable {
    enum Files: Equatable {
        case loading
        case loaded(NumstatParser.Files)
        case failed(String)
    }

    enum Commits: Equatable {
        case loading
        case loaded(LogParser.GraphPage)
        case failed(String)
    }

    /// The main selection when S-12 opened.
    var base: ObjectID
    /// The row whose menu opened it.
    var target: ObjectID
    var files: Files = .loading
    /// The commits between them (#389): what `target` has that `base` does not.
    var commits: Commits = .loading
    var selectedFile: GitPath?
    var patch: DiffLoadState?
    var showsAllFiles = false
}

/// What S-12 shows, built from the session and the graph's commits. Pure, so it is unit tested without views; every
/// text from the repository is escaped.
struct CommitComparisonModel: Equatable {
    struct CommitRow: Equatable {
        let oid: ObjectID
        let shortSHA: String
        let subject: String
        let author: String
        let isAIAssisted: Bool
        var accessibilityLabel: String {
            String(localized: "Commit \(shortSHA), \(subject), by \(author)")
                + (isAIAssisted ? ", " + String(localized: "AI-assisted") : "")
        }
    }

    enum State: Equatable {
        case loading(String)
        case noChanges(String)
        case failed(String)
        case loaded
    }

    /// `3c5d6f1 → a91f3c2`.
    let title: String
    let base: CommitRow
    let target: CommitRow
    let state: State
    /// FILES CHANGED, at most `CommitDetailModel.fileLimit` unless `Show all` was chosen.
    let rows: [CommitDetailModel.FileRow]
    let hidden: Int
    /// `8 files · +272 −85` once loaded.
    let summary: String?
    let totalLineChange: String
    /// The list was cut at the output limit.
    let isPartial: Bool
    /// COMMITS (#389): what the target has that the base does not, newest first.
    let commits: [CommitRow]
    /// More commits than listed (`RepositoryService.commitRangeLimit`).
    let hasMoreCommits: Bool
    /// Instead of the rows while they load, when they failed, or when there are none.
    let commitsNotice: String?

    init(session: CommitComparisonSession, commit: (ObjectID) -> CommitNode?, rule: AIAgentRule = .builtIn) {
        func row(_ oid: ObjectID) -> CommitRow {
            let node = commit(oid)
            return CommitRow(
                oid: oid, shortSHA: oid.short, subject: PathValidator.displayable(node?.subject ?? ""),
                author: PathValidator.displayable(node?.authorName ?? ""),
                isAIAssisted: node?.coAuthors.contains(where: rule.isAgent) ?? false)
        }
        base = row(session.base)
        target = row(session.target)
        title = "\(base.shortSHA) → \(target.shortSHA)"
        switch session.commits {
        case .loading:
            commits = []
            hasMoreCommits = false
            commitsNotice = "Reading commits…"
        case .failed(let message):
            commits = []
            hasMoreCommits = false
            commitsNotice = PathValidator.displayable(message)
        case .loaded(let page):
            // Rows come from the log itself: a commit between the two may not be loaded in the graph.
            commits = page.commits.map { node in
                CommitRow(
                    oid: node.oid, shortSHA: node.oid.short, subject: PathValidator.displayable(node.subject),
                    author: PathValidator.displayable(node.authorName),
                    isAIAssisted: node.coAuthors.contains(where: rule.isAgent))
            }
            hasMoreCommits = page.isPartial
            // The target may be behind the base (picked in either order); ⇄ shows the other direction.
            commitsNotice =
                page.commits.isEmpty ? "\(target.shortSHA) has no commits that \(base.shortSHA) does not have" : nil
        }
        switch session.files {
        case .loading:
            state = .loading(String(localized: "Comparing \(base.shortSHA) with \(target.shortSHA)…"))
            rows = []
            hidden = 0
            summary = nil
            totalLineChange = ""
            isPartial = false
        case .failed(let message):
            state = .failed(PathValidator.displayable(message))
            rows = []
            hidden = 0
            summary = nil
            totalLineChange = ""
            isPartial = false
        case .loaded(let list):
            let all = list.files.map(CommitDetailModel.fileRow)
            let shown = session.showsAllFiles ? all : Array(all.prefix(CommitDetailModel.fileLimit))
            rows = shown
            hidden = all.count - shown.count
            let added = list.files.compactMap(\.added).reduce(0, +)
            let deleted = list.files.compactMap(\.deleted).reduce(0, +)
            totalLineChange = "+\(added) −\(deleted)"
            let count = WipDetailModel.formatted(list.files.count)
            summary = "\(count) \(list.files.count == 1 ? "file" : "files") · \(totalLineChange)"
            isPartial = list.isPartial
            state =
                list.files.isEmpty
                ? .noChanges(String(localized: "No changes between \(base.shortSHA) and \(target.shortSHA)")) : .loaded
        }
    }
}
