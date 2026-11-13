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
            text.shortSHA, text.subject, renamedFrom.map { String(localized: "renamed from \($0)") },
            String(localized: "by \(text.author)"),
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
        String(localized: "History of \(PathValidator.displayable(path.display))")
    }

    /// The title cut where the header lays it out (#614): the words around the path (`History of `, or `의 이력` after
    /// it in Korean) never shorten, the directory gives way first from its start, and the file name stays whole as
    /// long as it fits.
    struct TitleParts: Equatable {
        let prefix: String
        let directory: String
        let name: String
        let suffix: String
    }

    static let pathMarker = "\u{FFFC}"

    /// - Parameter format: The localized title with `pathMarker` where the path goes (tests pass other languages').
    static func titleParts(_ path: GitPath, format: String = String(localized: "History of \(pathMarker)"))
        -> TitleParts
    {
        let around = format.components(separatedBy: pathMarker)
        let shown = PathValidator.displayable(path.display)
        let slash = shown.lastIndex(of: "/")
        return TitleParts(
            prefix: around.first ?? "", directory: slash.map { String(shown[...$0]) } ?? "",
            name: slash.map { String(shown[shown.index(after: $0)...]) } ?? shown,
            suffix: around.count > 1 ? around[1] : "")
    }

    static var empty: String { String(localized: "This file has no history yet") }

    /// Shown instead of the beginning when the output limit cut the history.
    static var cutAtLimit: String { String(localized: "History cut at the size limit · older commits are not shown") }

    /// `Beginning of history · created in a274c55 as Parser.swift`, once the oldest commit is loaded.
    static func beginning(_ entries: [FileHistoryEntry], isComplete: Bool, isCutAtLimit: Bool = false) -> String? {
        if isCutAtLimit { return entries.isEmpty ? nil : cutAtLimit }
        guard isComplete, let first = entries.last else { return nil }
        let path = PathValidator.displayable(first.path.display)
        return String(localized: "Beginning of history · created in \(first.commit.oid.short) as \(path)")
    }
}
