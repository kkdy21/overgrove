import Foundation

/// A file picked in S-11. Untracked files are previewed like in S-02; the others use the comparison patch.
struct ComparisonFile: Equatable, Sendable {
    let path: GitPath
    let isUntracked: Bool
}

/// How far the comparison got.
enum ComparisonLoadState: Equatable {
    case loading
    case loaded(WorktreeComparison)
    case failed(ComparisonError)
}

/// One open S-11 session for a worktree (#158).
struct ComparisonSession: Equatable {
    let worktree: GitPath
    var base: FullRefName?
    var includeUncommitted = true
    var bases: [FullRefName] = []
    var result: ComparisonLoadState = .loading
    var selectedFile: ComparisonFile?
    var patch: DiffLoadState?
    /// "Show all n files" was pressed (screens.md S-11, large comparison).
    var showsAllFiles = false
    /// The worktree's status when the result arrived, shown while the list cannot be read (#374).
    var workingState: WorkingState?
}

/// S-11 rows and texts (screens.md S-11). Pure, so it is unit tested without views; repository strings are escaped.
struct ComparisonModel: Equatable {
    struct FileRow: Equatable, Identifiable {
        let path: GitPath
        let kindLetter: String
        /// Leading directories (`internal/http/`) and the name or `{old → new}`, escaped (as in S-02).
        let directory: String
        let fileName: String
        /// The counts drawn in the row; `nil` for untracked files (#577).
        var lineCount: WipLineCount?
        /// The file also has uncommitted changes (shown with a `WIP` pill, no colour).
        let hasUncommittedChanges: Bool
        let isSelectable: Bool
        /// The old name of a renamed file, for its patch (#309).
        var originalPath: GitPath?
        /// `Modified, src/a.swift, also changed in the working tree, 2 lines added, 1 removed` (interaction.md §6.1).
        var accessibilityLabel = ""
        var id: GitPath { path }
    }

    struct CommitRow: Equatable, Identifiable {
        let id: ObjectID
        let shortSHA: String
        let subject: String
        let author: String
    }

    enum State: Equatable {
        case loading(String)
        case noChanges(String)
        case failed(message: String, canChooseBase: Bool)
        case loaded

        var phase: LoadPhase {
            switch self {
            case .loading: .loading
            case .noChanges: .empty
            case .failed: .failed
            case .loaded: .loaded
            }
        }
    }

    /// Files shown before `Show all n files`.
    static let fileLimit = 1_000

    /// `main`, `origin/main` (escaped), or `base branch` before one is known.
    let baseName: String
    let state: State
    /// `2 commits ahead · 0 behind · uncommitted: 5 files · 8 files · +272 −85`.
    let summary: String?
    let commits: [CommitRow]
    /// More commits than listed (`WorktreeComparison.commitLimit`).
    let hasMoreCommits: Bool
    /// The `Uncommitted changes` row at the top of COMMITS AHEAD: its file count, `nil` when hidden.
    let uncommittedFileCount: Int?
    let files: [FileRow]
    let totalFileCount: Int
    /// `+272 −85` for FILES CHANGED.
    let totalLineChange: String
    /// `Show all 4,213 files` when the list is capped.
    let showAllTitle: String?
    let isFileListPartial: Bool
    let untracked: [FileRow]
    /// Set when the worktree list failed to load after this comparison ran (#374, interaction.md §4.1): the last
    /// result stays, dimmed, under this notice, and nothing in it can be changed until a load succeeds.
    let staleNotice: String?

    static var listFailedNotice: String {
        String(localized: "The worktree list could not be read, so this comparison may be out of date.")
    }
    /// The worktree is still listed but its status was not read on the last load (#413).
    static var worktreeUnreadNotice: String {
        String(localized: "This worktree's status could not be read, so this comparison may be out of date.")
    }

    /// - Parameter staleNotice: Why the result may be out of date (`listFailedNotice`, `worktreeUnreadNotice`), or
    ///   `nil` when it is current.
    init(session: ComparisonSession, workingState: WorkingState?, staleNotice: String? = nil) {
        self.staleNotice = staleNotice
        let baseName = session.base.map(Self.shortName) ?? String(localized: "base branch")
        self.baseName = baseName
        let uncommitted = Set(((workingState?.staged ?? []) + (workingState?.unstaged ?? [])).map(\.path))
        switch session.result {
        case .loading:
            state = .loading(String(localized: "Comparing with \(baseName)…"))
            summary = nil
            commits = []
            hasMoreCommits = false
            uncommittedFileCount = nil
            files = []
            totalFileCount = 0
            totalLineChange = ""
            showAllTitle = nil
            isFileListPartial = false
            untracked = []
        case .failed(let error):
            switch error {
            // The message can carry masked stderr, which still keeps separators such as U+2028.
            case .noBaseBranch, .baseNotFound:
                state = .failed(message: PathValidator.displayable(error.message), canChooseBase: true)
            default: state = .failed(message: PathValidator.displayable(error.message), canChooseBase: false)
            }
            summary = nil
            commits = []
            hasMoreCommits = false
            uncommittedFileCount = nil
            files = []
            totalFileCount = 0
            totalLineChange = ""
            showAllTitle = nil
            isFileListPartial = false
            untracked = []
        case .loaded(let comparison):
            let all = comparison.files.sorted {
                $0.path.display.localizedStandardCompare($1.path.display) == .orderedAscending
            }
            let shown = session.showsAllFiles ? all : Array(all.prefix(Self.fileLimit))
            files = shown.map { Self.fileRow($0, uncommitted: comparison.includesWorkingTree ? uncommitted : []) }
            totalFileCount = all.count
            showAllTitle =
                all.count > shown.count
                ? String(localized: "Show all \(WipDetailModel.formatted(all.count)) files") : nil
            isFileListPartial = comparison.isFileListPartial
            untracked = comparison.untracked.map {
                Self.fileRow(
                    FileStat(
                        path: $0, originalPath: nil, status: .untracked, added: nil, deleted: nil, isFromUntracked: true
                    ),
                    uncommitted: [])
            }
            commits = comparison.commits.map {
                CommitRow(
                    id: $0.oid, shortSHA: $0.oid.short, subject: PathValidator.displayable($0.subject),
                    author: PathValidator.displayable($0.authorName))
            }
            hasMoreCommits = comparison.isCommitListPartial
            let uncommittedInList =
                comparison.includesWorkingTree ? all.filter { uncommitted.contains($0.path) }.count : 0
            uncommittedFileCount = comparison.includesWorkingTree && uncommittedInList > 0 ? uncommittedInList : nil
            let added = all.compactMap(\.added).reduce(0, +)
            let deleted = all.compactMap(\.deleted).reduce(0, +)
            totalLineChange = "+\(WipDetailModel.formatted(added)) −\(WipDetailModel.formatted(deleted))"
            summary = Self.summary(comparison, uncommittedFiles: uncommittedInList, totalLineChange: totalLineChange)
            state =
                all.isEmpty && comparison.untracked.isEmpty && comparison.commits.isEmpty
                ? .noChanges(String(localized: "No changes compared with \(baseName)")) : .loaded
        }
    }

    /// `refs/heads/main` → `main`, `refs/remotes/origin/main` → `origin/main`.
    static func shortName(_ ref: FullRefName) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where ref.value.hasPrefix(prefix) {
            return PathValidator.displayable(String(ref.value.dropFirst(prefix.count)))
        }
        return PathValidator.displayable(ref.value)
    }

    private static func summary(_ comparison: WorktreeComparison, uncommittedFiles: Int, totalLineChange: String)
        -> String
    {
        var parts: [String] = []
        if let counts = comparison.counts {
            let ahead = counts.ahead
            parts.append(
                (ahead == 1 ? String(localized: "\(ahead) commit ahead") : String(localized: "\(ahead) commits ahead"))
                    + " · " + String(localized: "\(counts.behind) behind"))
        } else {
            let count = comparison.commits.count
            let shown = "\(count)\(comparison.isCommitListPartial ? "+" : "")"
            parts.append(
                count == 1 ? String(localized: "\(shown) commit ahead") : String(localized: "\(shown) commits ahead"))
        }
        if comparison.includesWorkingTree {
            parts.append(
                uncommittedFiles == 1
                    ? String(localized: "uncommitted: \(uncommittedFiles) file")
                    : String(localized: "uncommitted: \(uncommittedFiles) files"))
        }
        let files = comparison.files.count
        let fileCount = WipDetailModel.formatted(files)
        parts.append(files == 1 ? String(localized: "\(fileCount) file") : String(localized: "\(fileCount) files"))
        parts.append(totalLineChange)
        return parts.joined(separator: " · ")
    }

    private static func fileRow(_ stat: FileStat, uncommitted: Set<GitPath>) -> FileRow {
        let change = FileChange(path: stat.path, originalPath: stat.originalPath, status: stat.status ?? .modified)
        let (directory, fileName) = WipDetailModel.displayParts(change)
        return FileRow(
            path: stat.path, kindLetter: String((stat.status ?? .modified).code), directory: directory,
            fileName: fileName, lineCount: stat.isFromUntracked ? nil : stat.lineCount,
            hasUncommittedChanges: uncommitted.contains(stat.path),
            isSelectable: stat.path.isRepresentable && (stat.originalPath?.isRepresentable ?? true),
            originalPath: stat.originalPath,
            accessibilityLabel: WipDetailModel.fileAccessibilityLabel(
                stat,
                extras: uncommitted.contains(stat.path) ? [String(localized: "also changed in the working tree")] : []))
    }
}
