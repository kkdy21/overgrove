import Foundation

/// One S-09 row (screens.md S-09): SHA, subject, author, date, and this file's `+n −m`, with `renamed from …` on the
/// commit that renamed it. Every repository string is escaped.
struct FileHistoryRow: Identifiable, Equatable {
    let id: ObjectID
    let text: GraphCommitText
    /// `+42 −8`, `binary`, or empty when git printed no stat for the commit.
    let stat: String
    /// The old path, escaped, when this commit renamed the file.
    let renamedFrom: String?
    let accessibilityLabel: String

    init(_ entry: FileHistoryEntry, now: Date) {
        id = entry.id
        text = GraphCommitText(entry.commit, now: now)
        stat = Self.stat(entry)
        renamedFrom = entry.originalPath.map { PathValidator.displayable($0.display) }
        accessibilityLabel = [
            text.shortSHA, text.subject, renamedFrom.map { "renamed from \($0)" }, "by \(text.author)",
            text.absoluteDate, stat.isEmpty ? nil : stat,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    static func stat(_ entry: FileHistoryEntry) -> String {
        guard entry.hasStat else { return "" }
        guard let added = entry.added, let deleted = entry.deleted else { return "binary" }
        return "+\(added) −\(deleted)"
    }
}

/// S-09's header and the line under the last row (screens.md S-09 states).
enum FileHistoryText {
    static func title(_ path: GitPath) -> String {
        "History of " + PathValidator.displayable(path.display)
    }

    static let empty = "This file has no history yet"

    /// Shown instead of the beginning when the output limit cut the history.
    static let cutAtLimit = "History cut at the size limit · older commits are not shown"

    /// `Beginning of history · created in a274c55 as Parser.swift`, once the oldest commit is loaded.
    static func beginning(_ entries: [FileHistoryEntry], isComplete: Bool, isCutAtLimit: Bool = false) -> String? {
        if isCutAtLimit { return entries.isEmpty ? nil : cutAtLimit }
        guard isComplete, let first = entries.last else { return nil }
        return "Beginning of history · created in \(first.commit.oid.short) as "
            + PathValidator.displayable(first.path.display)
    }
}
