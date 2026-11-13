import Foundation

/// One row of the sidebar's STASHES section (information-architecture.md §4).
struct StashRow: Identifiable, Equatable {
    let id: ObjectID
    /// `stash@{0}`.
    let refName: String
    /// The message (or subject), escaped.
    let message: String
    let date: Date
    let accessibilityLabel: String

    init(_ stash: Stash) {
        id = stash.oid
        refName = stash.refName
        message = PathValidator.displayable(stash.message)
        date = stash.date
        accessibilityLabel = "\(stash.refName), \(message)"
    }
}

/// What S-04 shows while a stash's files load.
enum StashDetailState: Equatable {
    case loading
    case loaded(StashDetail)
    case unavailable(String)
}

/// S-04, one stash (screens.md S-04). Pure, so it is unit tested without views; repository strings are escaped.
struct StashDetailModel: Equatable {
    struct FileRow: Equatable, Identifiable {
        let file: FileStat
        let directory: String
        let fileName: String
        /// From the stash's untracked-files commit (shown with a `?` badge and a legend line with the same badge).
        let isFromUntracked: Bool
        let isSelectable: Bool
        /// `src/a.swift, 2 lines added, 1 removed, from untracked files` (interaction.md §6.1).
        var accessibilityLabel: String {
            WipDetailModel.fileAccessibilityLabel(
                file, extras: isFromUntracked ? [String(localized: "from untracked files")] : [])
        }
        var id: GitPath { file.path }
    }

    let refName: String
    /// For the Copy Ref tooltip: `stash@{n}` shifts when stashes change, the OID does not.
    let oid: String
    let date: Date
    /// The full reflog subject, escaped.
    let subject: String
    /// `9c8d7e6`, and the commit subject when the stash message names the same commit (`WIP on b: 9c8d7e6 subject`),
    /// marked `(from message)`: it is the message's text, not read from the commit.
    let baseCommit: String?
    /// The branch read from the message, escaped; shown with `(from message)`.
    let branch: String?
    /// `index · working tree · untracked`.
    let includes: String
    let files: [FileRow]?
    let filesUnavailable: String?
    let isFileListPartial: Bool

    init(stash: Stash, state: StashDetailState) {
        refName = stash.refName
        oid = stash.oid.hex
        date = stash.date
        subject = PathValidator.displayable(stash.subject)
        branch = stash.branch.map(PathValidator.displayable)
        baseCommit = stash.baseCommit.map { Self.baseCommitText($0, message: stash.message) }
        var parts: [String] = []
        if stash.includesIndex { parts.append(String(localized: "index", comment: "Stash includes")) }
        parts.append(String(localized: "working tree", comment: "Stash includes"))
        if stash.includesUntracked { parts.append(String(localized: "untracked", comment: "Stash includes")) }
        includes = parts.joined(separator: " · ")
        switch state {
        case .loading:
            files = nil
            filesUnavailable = nil
            isFileListPartial = false
        case .loaded(let detail):
            files = detail.files.map(Self.row)
            filesUnavailable = nil
            isFileListPartial = detail.isPartial
        case .unavailable(let reason):
            files = nil
            filesUnavailable = PathValidator.displayable(reason)
            isFileListPartial = false
        }
    }

    var hasUntrackedFiles: Bool { files?.contains(where: \.isFromUntracked) ?? false }

    /// `WIP on b: 9c8d7e6 docs: …` puts the base commit's short SHA and subject first. Show that subject only when the
    /// short SHA matches the real first parent; the message itself is just text the user (or git) wrote.
    static func baseCommitText(_ base: ObjectID, message: String) -> String {
        let parts = message.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].count >= 7, base.hex.hasPrefix(parts[0]) {
            return "\(base.short)  \(PathValidator.displayable(String(parts[1])))  "
                + String(localized: "(from message)")
        }
        return base.short
    }

    private static func row(_ file: FileStat) -> FileRow {
        let change = FileChange(path: file.path, originalPath: file.originalPath, status: file.status ?? .modified)
        let (directory, fileName) = WipDetailModel.displayParts(change)
        return FileRow(
            file: file, directory: directory, fileName: fileName,
            isFromUntracked: file.isFromUntracked,
            isSelectable: file.path.isRepresentable && (file.originalPath?.isRepresentable ?? true))
    }
}
