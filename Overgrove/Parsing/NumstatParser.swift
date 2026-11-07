import Foundation

/// Parses the file list of a commit (`diff-tree -r -z --raw --numstat -M`, parsing-spec.md §8.1) and of a stash
/// (`stash show --include-untracked --numstat -z`, §8.2), and a worktree's line counts (`diff --numstat -z`, §8.3).
///
/// Records are read by position, never by guessing from content: a path such as `:x` or one containing tabs cannot be
/// mistaken for a record start. Paths stay raw bytes (`GitPath`) because they go back to git for patches. Modes, OIDs,
/// status letters and counts are checked strictly; a malformed field fails the whole parse with its byte offset
/// (§1.6), since reading on would attach one file's numbers to another.
enum NumstatParser {
    struct Files: Sendable, Equatable {
        let files: [FileStat]
        /// The output was cut at the size limit and the last incomplete record was dropped.
        let isPartial: Bool
    }

    private static let name = "NumstatParser"
    private static let colon = UInt8(ascii: ":")
    private static let tab = UInt8(ascii: "\t")
    private static let space = UInt8(ascii: " ")

    fileprivate typealias Token = Data.SubSequence

    /// `diff-tree --raw --numstat` output: every raw record first, then one numstat record per raw record in the same
    /// order (confirmed with Apple Git 2.50.1). Status comes from raw, line counts from numstat; each pair must name the
    /// same new path (and the same old path for renames and copies).
    ///
    /// When `truncated`, files whose numstat record was cut off are dropped: their counts are unknown, and `nil`
    /// counts would wrongly mean "binary".
    static func parseCommitFiles(_ data: Data, truncated: Bool = false) throws -> Files {
        var reader = try TokenReader(data, truncated: truncated)
        var raws: [RawRecord] = []
        var seenPaths = Set<Data>()
        while reader.peek()?.first == colon, let raw = try readRaw(&reader) {
            guard seenPaths.insert(raw.path).inserted else { throw failure("duplicate path", at: raw.offset) }
            raws.append(raw)
        }

        var files: [FileStat] = []
        files.reserveCapacity(raws.count)
        var next = 0
        while !reader.isAtEnd, let stat = try readNumstat(&reader) {
            // A working-tree record git found unchanged after all has no numstat (PAR-NUMSTAT-07, #305).
            while next < raws.count, raws[next].isWorkingTreeSide, !stat.matches(raws[next]) { next += 1 }
            guard next < raws.count else {
                throw failure("numstat record without raw record", at: stat.offset)
            }
            let raw = raws[next]
            guard stat.matches(raw) else {
                throw failure("numstat record does not match raw record", at: stat.offset)
            }
            files.append(stat.fileStat(status: raw.status, isFromUntracked: false))
            next += 1
        }
        if !truncated, let missing = raws[next...].first(where: { !$0.isWorkingTreeSide }) {
            throw failure("raw record without numstat record", at: missing.offset)
        }
        return Files(files: files, isPartial: truncated)
    }

    /// `stash show --include-untracked --numstat -z` output: numstat records only, so `status` stays `nil`.
    ///
    /// The output itself does not say which files came from the untracked part (§8.2). Those are exactly the files of
    /// the stash's third parent, a root commit holding the untracked tree: pass the paths from
    /// `parseCommitFiles` of `commitFiles(<stash>^3)` as `untrackedPaths` (PAR-NUMSTAT-05). Matching is by raw bytes.
    static func parseStashFiles(
        _ data: Data,
        untrackedPaths: Set<GitPath> = [],
        truncated: Bool = false
    ) throws -> Files {
        var reader = try TokenReader(data, truncated: truncated)
        var files: [FileStat] = []
        var seenPaths = Set<Data>()
        while !reader.isAtEnd, let stat = try readNumstat(&reader) {
            guard seenPaths.insert(stat.path).inserted else { throw failure("duplicate path", at: stat.offset) }
            let path = GitPath(raw: Data(stat.path))
            files.append(stat.fileStat(status: nil, isFromUntracked: untrackedPaths.contains(path)))
        }
        return Files(files: files, isPartial: truncated)
    }

    /// `diff [--cached] --numstat -z -M` output of a worktree (§8.3, #230): numstat records only, so `status` stays
    /// `nil`.
    ///
    /// An unmerged path prints two records in the unstaged output (`0 0`, then stage 2 against the worktree), so the
    /// caller passes the status's conflicted paths as `excluding` and their records are dropped. Any other repeated
    /// path fails the parse. Matching is by raw bytes.
    static func parseWorktreeFiles(
        _ data: Data,
        excluding excluded: Set<GitPath> = [],
        truncated: Bool = false
    ) throws -> Files {
        var reader = try TokenReader(data, truncated: truncated)
        var files: [FileStat] = []
        var seenPaths = Set<Data>()
        while !reader.isAtEnd, let stat = try readNumstat(&reader) {
            let path = GitPath(raw: Data(stat.path))
            guard !excluded.contains(path) else { continue }
            guard seenPaths.insert(stat.path).inserted else { throw failure("duplicate path", at: stat.offset) }
            files.append(stat.fileStat(status: nil, isFromUntracked: false))
        }
        return Files(files: files, isPartial: truncated)
    }

    fileprivate static func failure(_ reason: String, at offset: Int) -> ParseError {
        ParseError(parser: name, offset: offset, reason: reason)
    }
}

// MARK: - Records

extension NumstatParser {
    private struct RawRecord {
        let status: FileChange.Status
        let originalPath: Token?
        let path: Token
        let offset: Int
        /// The destination object name is all zeros: the file is read from the working tree, so git only decides
        /// whether it changed when it diffs it. A stat-only change (mtime touched, content the same) then has no
        /// numstat record.
        let isWorkingTreeSide: Bool
    }

    private struct NumstatRecord {
        let added: Int?
        let deleted: Int?
        let originalPath: Token?
        let path: Token
        let offset: Int

        func matches(_ raw: RawRecord) -> Bool { path == raw.path && originalPath == raw.originalPath }

        func fileStat(status: FileChange.Status?, isFromUntracked: Bool) -> FileStat {
            FileStat(
                path: GitPath(raw: Data(path)),
                originalPath: originalPath.map { GitPath(raw: Data($0)) },
                status: status,
                added: added,
                deleted: deleted,
                isFromUntracked: isFromUntracked
            )
        }
    }

    private enum Count: Equatable {
        case lines(Int)
        case binary
    }

    /// `:<srcmode> <dstmode> <srcoid> <dstoid> <status>[score]␀<path>␀`, plus `<new path>␀` for `R` and `C`.
    /// Returns `nil` when a truncated output ends inside the record.
    private static func readRaw(_ reader: inout TokenReader) throws -> RawRecord? {
        guard let meta = try reader.next() else { return nil }
        let offset = reader.offset(of: meta)
        let (status, isWorkingTreeSide) = try rawStatus(meta, offset: offset)
        guard let first = try reader.path() else { return nil }
        switch status {
        case .renamed, .copied:
            guard let second = try reader.path() else { return nil }
            return RawRecord(
                status: status, originalPath: first, path: second, offset: offset, isWorkingTreeSide: isWorkingTreeSide)
        default:
            return RawRecord(
                status: status, originalPath: nil, path: first, offset: offset, isWorkingTreeSide: isWorkingTreeSide)
        }
    }

    /// `<added>\t<deleted>\t<path>␀`, or `<added>\t<deleted>\t␀<old>␀<new>␀` for renames and copies. The path is the
    /// rest of the token and may contain tabs. Returns `nil` when a truncated output ends inside the record.
    private static func readNumstat(_ reader: inout TokenReader) throws -> NumstatRecord? {
        guard let token = try reader.next() else { return nil }
        let offset = reader.offset(of: token)
        let addedEnd = token.firstIndex(of: tab) ?? token.endIndex
        let added = try count(token[..<addedEnd], field: "added", offset: offset)
        let rest = token[addedEnd...].dropFirst()
        let deletedEnd = rest.firstIndex(of: tab)
        let deleted = try count(rest[..<(deletedEnd ?? rest.endIndex)], field: "deleted", offset: offset)
        guard let deletedEnd else { throw failure("invalid deleted count", at: offset) }
        let (addedLines, deletedLines) = try lineCounts(added, deleted, offset: offset)

        let path = rest[deletedEnd...].dropFirst()
        if !path.isEmpty {
            return NumstatRecord(
                added: addedLines, deleted: deletedLines, originalPath: nil, path: path, offset: offset)
        }
        // An empty third field marks a rename or copy; the old and new paths follow as separate tokens.
        guard let old = try reader.path(), let new = try reader.path() else { return nil }
        return NumstatRecord(added: addedLines, deleted: deletedLines, originalPath: old, path: new, offset: offset)
    }

    // MARK: Fields

    private static func rawStatus(_ meta: Token, offset: Int) throws -> (FileChange.Status, isWorkingTreeSide: Bool) {
        let parts = meta.dropFirst().split(separator: space, omittingEmptySubsequences: false)
        guard parts.count == 5, isMode(parts[0]), isMode(parts[1]),
            let source = ObjectID(text(parts[2])), let destination = ObjectID(text(parts[3])),
            source.isSHA256 == destination.isSHA256
        else { throw failure("invalid raw record", at: offset) }
        guard let status = status(parts[4]) else { throw failure("invalid status", at: offset) }
        return (status, destination.hex.utf8.allSatisfy { $0 == UInt8(ascii: "0") })
    }

    /// git prints modes as exactly six octal digits (`%06o`), e.g. `000000`, `100644`, `120000`, `160000`.
    private static func isMode(_ field: Token) -> Bool {
        field.count == 6 && field.allSatisfy { (0x30...0x37).contains($0) }
    }

    /// `A`, `M`, `D`, `T` take no score; `R` and `C` take an optional similarity score of 0–100.
    private static func status(_ field: Token) -> FileChange.Status? {
        guard let letter = field.first else { return nil }
        let scoreField = field.dropFirst()
        switch letter {
        case UInt8(ascii: "A"): return scoreField.isEmpty ? .added : nil
        case UInt8(ascii: "M"): return scoreField.isEmpty ? .modified : nil
        case UInt8(ascii: "D"): return scoreField.isEmpty ? .deleted : nil
        case UInt8(ascii: "T"): return scoreField.isEmpty ? .typeChanged : nil
        case UInt8(ascii: "R"), UInt8(ascii: "C"):
            let score: Int?
            if scoreField.isEmpty {
                score = nil
            } else {
                guard scoreField.count <= 3, let value = decimal(scoreField), value <= 100 else { return nil }
                score = value
            }
            return letter == UInt8(ascii: "R") ? .renamed(score: score) : .copied(score: score)
        default:
            return nil
        }
    }

    /// A count is unsigned ASCII decimal (§1.8), or `-` for a binary file.
    private static func count(_ field: Token, field fieldName: String, offset: Int) throws -> Count {
        if field.elementsEqual([UInt8(ascii: "-")]) { return .binary }
        guard let value = decimal(field) else { throw failure("invalid \(fieldName) count", at: offset) }
        return .lines(value)
    }

    private static func lineCounts(_ added: Count, _ deleted: Count, offset: Int) throws -> (Int?, Int?) {
        switch (added, deleted) {
        case (.lines(let added), .lines(let deleted)): return (added, deleted)
        case (.binary, .binary): return (nil, nil)
        default: throw failure("binary marker in one count only", at: offset)
        }
    }

    /// ASCII digits only; no sign, no whitespace. `nil` on overflow.
    private static func decimal(_ field: Token) -> Int? {
        guard !field.isEmpty, field.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(text(field))
    }

    private static func text(_ token: Token) -> String {
        String(decoding: token, as: UTF8.self)
    }
}

// MARK: - Tokens

/// NUL-separated tokens with the truncation rule of parsing-spec.md §1.5: a token is complete only when its NUL
/// survived, so the fragment after the last NUL is dropped and a record still missing tokens ends the parse.
private struct TokenReader {
    private let data: Data
    private let truncated: Bool
    private let tokens: [NumstatParser.Token]
    private var index = 0

    init(_ data: Data, truncated: Bool) throws {
        var tokens = data.split(separator: 0, omittingEmptySubsequences: false)
        // After the final NUL comes an empty token when the output is complete, or a cut-off fragment.
        let tail = tokens.removeLast()
        guard truncated || tail.isEmpty else {
            throw NumstatParser.failure("incomplete record", at: data.count)
        }
        self.data = data
        self.truncated = truncated
        self.tokens = tokens
    }

    var isAtEnd: Bool { index == tokens.count }

    func peek() -> NumstatParser.Token? { isAtEnd ? nil : tokens[index] }

    func offset(of token: NumstatParser.Token) -> Int { token.startIndex - data.startIndex }

    /// The next token, or `nil` when a truncated output ends here. Complete output must not end inside a record.
    mutating func next() throws -> NumstatParser.Token? {
        guard !isAtEnd else {
            if truncated { return nil }
            throw NumstatParser.failure("incomplete record", at: data.count)
        }
        defer { index += 1 }
        return tokens[index]
    }

    /// Like `next()`, but the token must be a non-empty path.
    mutating func path() throws -> NumstatParser.Token? {
        guard let token = try next() else { return nil }
        guard !token.isEmpty else { throw NumstatParser.failure("empty path", at: offset(of: token)) }
        return token
    }
}
