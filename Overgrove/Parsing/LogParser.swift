import Foundation

/// Parses `git log -z` output for the graph, file history and commit detail (parsing-spec.md §5).
///
/// Every field is NUL-terminated, so tokens are grouped by a fixed count. git cuts a commit message at its first NUL
/// (PAR-LOG-08), but that alone does not keep fields aligned: a repository's `i18n.logOutputEncoding` or
/// `i18n.commitEncoding` re-encodes the whole output, and some encodings turn message text into NUL bytes (#205).
/// A malformed field fails the whole parse instead of resynchronizing: a shifted record would attach one commit's
/// parents to another.
///
/// The formats never use signature placeholders (`%G?`, `%GS`, …): those run `gpg.program` (T7). The parser only
/// reads the fields listed below, and `GitCommand` owns the format strings.
enum LogParser {
    /// One page of `%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%(trailers:…)` records (§5.1).
    struct GraphPage: Sendable, Equatable {
        let commits: [CommitNode]
        /// The output was cut at the size limit and the last record was dropped.
        let isPartial: Bool
    }

    /// One page of a file's history (§5.3).
    struct FileHistoryPage: Sendable, Equatable {
        let entries: [FileHistoryEntry]
        /// The output was cut at the size limit and the last record was dropped.
        let isPartial: Bool
    }

    /// `%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%ce%x00%ct%x00%B` for one commit (§5.2). Files come from a separate
    /// `diff-tree` call; combine them with `detail(files:isPartial:)`.
    struct CommitMeta: Sendable, Equatable {
        let oid: ObjectID
        let parents: [ObjectID]
        let authorName: String
        let authorEmail: String
        let authorDate: Date
        let committerName: String
        let committerEmail: String
        let committerDate: Date
        /// Full message; trailing newlines are preserved and trimmed only for display.
        let message: String
        /// The output was cut at the size limit, so `message` may be incomplete.
        let isPartial: Bool

        func detail(files: [FileStat], isPartial filesArePartial: Bool) -> CommitDetail {
            CommitDetail(
                oid: oid,
                parents: parents,
                authorName: authorName,
                authorEmail: authorEmail,
                authorDate: authorDate,
                committerName: committerName,
                committerEmail: committerEmail,
                committerDate: committerDate,
                message: message,
                files: files,
                isPartial: isPartial || filesArePartial
            )
        }
    }

    private static let name = "LogParser"
    /// Fields per graph record: `%H`, `%P`, `%an`, `%ae`, `%at`, `%s`, and the trailers of `ReadOnlyGitCommand.logFormat`,
    /// each NUL-terminated with `-z`. `GraphStreamParser` cuts records with the same count (#254).
    static let graphFieldCount = 7
    private static let detailFieldCount = 9

    private typealias Token = Data.SubSequence

    static func parseGraph(_ data: Data, truncated: Bool = false) throws -> GraphPage {
        var tokens = data.split(separator: 0, omittingEmptySubsequences: false)
        if truncated {
            // The last token is either cut off or the empty one after a final NUL. Dropping it, then any leftover
            // fields, removes a record that may be incomplete while keeping records proven complete by their NUL.
            tokens.removeLast()
            tokens.removeLast(tokens.count % graphFieldCount)
        } else {
            tokens.removeLast()  // every record ends with NUL, so the last token is empty when the output is complete
            guard data.isEmpty || data.last == 0, tokens.count % graphFieldCount == 0 else {
                throw ParseError(parser: name, offset: data.count, reason: "incomplete record")
            }
        }

        var commits: [CommitNode] = []
        commits.reserveCapacity(tokens.count / graphFieldCount)
        for start in stride(from: 0, to: tokens.count, by: graphFieldCount) {
            let fields = tokens[start..<start + graphFieldCount]
            commits.append(
                CommitNode(
                    oid: try commitOID(fields[start], in: data),
                    parents: try parentOIDs(fields[start + 1], in: data),
                    authorName: text(fields[start + 2]),
                    authorEmail: text(fields[start + 3]),
                    authorDate: try date(fields[start + 4], field: "author time", in: data),
                    subject: text(fields[start + 5]),
                    coAuthors: coAuthors(fields[start + 6])
                )
            )
        }
        return GraphPage(commits: commits, isPartial: truncated)
    }

    /// One page of `git log [--follow] -z <format> --numstat -- <path>` (§5.3). After a record's seven fields, a
    /// commit that changed the file has `\n` and one numstat entry: `added\tdeleted\tpath`, or for a rename
    /// `added\tdeleted\t` followed by the old and the new path as their own NUL-terminated tokens. `-` counts are a
    /// binary file. A record without a stat (a merge) is followed directly by the next record.
    ///
    /// - Parameter path: The followed path at the newest commit of this page (the requested path, or for a later page
    ///   the path before the previous page's oldest commit); records without a stat keep it.
    static func parseFileHistory(_ data: Data, path: GitPath, truncated: Bool = false) throws -> FileHistoryPage {
        var tokens = data.split(separator: 0, omittingEmptySubsequences: false)
        tokens.removeLast()  // empty after the final NUL, or cut off when truncated
        if !truncated, !data.isEmpty, data.last != 0 {
            throw ParseError(parser: name, offset: data.count, reason: "incomplete record")
        }
        var entries: [FileHistoryEntry] = []
        var current = path
        var index = 0
        while index < tokens.count {
            guard index + graphFieldCount <= tokens.count else {
                if truncated { break }
                throw ParseError(parser: name, offset: data.count, reason: "incomplete record")
            }
            let fields = tokens[index..<index + graphFieldCount]
            let commit = CommitNode(
                oid: try commitOID(fields[index], in: data),
                parents: try parentOIDs(fields[index + 1], in: data),
                authorName: text(fields[index + 2]),
                authorEmail: text(fields[index + 3]),
                authorDate: try date(fields[index + 4], field: "author time", in: data),
                subject: text(fields[index + 5]),
                coAuthors: coAuthors(fields[index + 6]))
            index += graphFieldCount
            var entry = FileHistoryEntry(commit: commit, path: current)
            if index < tokens.count, tokens[index].first == newline {
                guard let stat = try numstat(tokens, at: index, in: data, truncated: truncated) else { break }
                index = stat.next
                entry = FileHistoryEntry(
                    commit: commit, path: stat.path, originalPath: stat.originalPath, added: stat.added,
                    deleted: stat.deleted, hasStat: true)
            }
            entries.append(entry)
            current = entry.originalPath ?? entry.path
        }
        // A cut page may end in a record whose stat was cut away; drop it rather than show it without one.
        if truncated, !entries.isEmpty { entries.removeLast() }
        return FileHistoryPage(entries: entries, isPartial: truncated)
    }

    private static let newline = UInt8(ascii: "\n")

    /// `\nadded\tdeleted\tpath`, or `\nadded\tdeleted\t` + old + new. `nil` when a truncated page ends inside it.
    private static func numstat(_ tokens: [Token], at index: Int, in data: Data, truncated: Bool) throws -> (
        added: Int?, deleted: Int?, path: GitPath, originalPath: GitPath?, next: Int
    )? {
        let line = tokens[index].dropFirst()
        let parts = line.split(separator: UInt8(ascii: "\t"), maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw ParseError(parser: name, offset: offset(of: tokens[index], in: data), reason: "invalid numstat")
        }
        let added = try count(parts[0], in: data)
        let deleted = try count(parts[1], in: data)
        if !parts[2].isEmpty {
            return (added, deleted, GitPath(raw: Data(parts[2])), nil, index + 1)
        }
        guard index + 2 < tokens.count else {
            if truncated { return nil }
            throw ParseError(parser: name, offset: data.count, reason: "incomplete rename")
        }
        let old = tokens[index + 1]
        let new = tokens[index + 2]
        guard !old.isEmpty, !new.isEmpty else {
            throw ParseError(parser: name, offset: offset(of: old, in: data), reason: "empty rename path")
        }
        return (added, deleted, GitPath(raw: Data(new)), GitPath(raw: Data(old)), index + 3)
    }

    /// A numstat count: ASCII digits, or `-` for a binary file (`nil`).
    private static func count(_ token: Token, in data: Data) throws -> Int? {
        if token.count == 1, token.first == UInt8(ascii: "-") { return nil }
        guard !token.isEmpty, token.count <= 18, token.allSatisfy({ (0x30...0x39).contains($0) }),
            let value = Int(text(token))
        else { throw ParseError(parser: name, offset: offset(of: token, in: data), reason: "invalid numstat count") }
        return value
    }

    static func parseCommitMeta(_ data: Data, truncated: Bool = false) throws -> CommitMeta {
        var tokens = data.split(separator: 0, omittingEmptySubsequences: false)
        if data.last == 0 {
            tokens.removeLast()  // the record ends with NUL
        } else if !truncated {
            throw ParseError(parser: name, offset: data.count, reason: "incomplete record")
        }
        // When truncated without a final NUL, the cut message is still worth showing, flagged by `isPartial`.
        guard tokens.count >= detailFieldCount else {
            throw ParseError(parser: name, offset: data.count, reason: "incomplete record")
        }
        guard tokens.count == detailFieldCount else {
            let offset = tokens[detailFieldCount].startIndex - data.startIndex
            throw ParseError(parser: name, offset: offset, reason: "more than one record")
        }
        return CommitMeta(
            oid: try commitOID(tokens[0], in: data),
            parents: try parentOIDs(tokens[1], in: data),
            authorName: text(tokens[2]),
            authorEmail: text(tokens[3]),
            authorDate: try date(tokens[4], field: "author time", in: data),
            committerName: text(tokens[5]),
            committerEmail: text(tokens[6]),
            committerDate: try date(tokens[7], field: "committer time", in: data),
            message: text(tokens[8]),
            isPartial: truncated
        )
    }

    // MARK: - Fields

    private static func text(_ token: Token) -> String {
        String(decoding: token, as: UTF8.self)
    }

    /// `%(trailers:key=Co-authored-by,valueonly,unfold,separator=%x1f)`: values separated by U+001F, empty when the
    /// commit has none. Display only, so decoded leniently; blank values are dropped.
    private static func coAuthors(_ token: Token) -> [String] {
        token.split(separator: unitSeparator).compactMap { part in
            let value = text(part).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }

    private static let unitSeparator: UInt8 = 0x1F

    private static func offset(of token: Token, in data: Data) -> Int {
        token.startIndex - data.startIndex
    }

    private static func commitOID(_ token: Token, in data: Data) throws -> ObjectID {
        guard let oid = ObjectID(text(token)) else {
            throw ParseError(parser: name, offset: offset(of: token, in: data), reason: "invalid commit OID")
        }
        return oid
    }

    /// Space-separated OIDs: empty for a root commit, two or more for merges. Order is kept (first parent first).
    private static func parentOIDs(_ token: Token, in data: Data) throws -> [ObjectID] {
        guard !token.isEmpty else { return [] }
        return try token.split(separator: 0x20, omittingEmptySubsequences: false).map { part in
            guard let oid = ObjectID(text(part)) else {
                throw ParseError(parser: name, offset: offset(of: part, in: data), reason: "invalid parent OID")
            }
            return oid
        }
    }

    /// Epoch seconds: ASCII decimal digits only, no sign (parsing-spec.md §1.8).
    private static func date(_ token: Token, field: String, in data: Data) throws -> Date {
        guard !token.isEmpty, token.allSatisfy({ (0x30...0x39).contains($0) }), let seconds = Int64(text(token))
        else { throw ParseError(parser: name, offset: offset(of: token, in: data), reason: "invalid \(field)") }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
