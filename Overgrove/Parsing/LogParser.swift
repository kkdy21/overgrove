import Foundation

/// Parses `git log -z` output for the graph, file history and commit detail (parsing-spec.md §5).
///
/// Every field is NUL-terminated, so tokens are grouped by a fixed count. git cuts a commit message at its first NUL,
/// so a message can never shift the fields that follow (PAR-LOG-08). A malformed field fails the whole parse instead
/// of resynchronizing: a shifted record would attach one commit's parents to another.
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
    private static let graphFieldCount = 7
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
