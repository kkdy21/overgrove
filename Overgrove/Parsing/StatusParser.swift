import Foundation

/// Parses `git status --porcelain=v2 -z --branch --show-stash --untracked-files=all --ignore-submodules=dirty`
/// (parsing-spec.md §3).
///
/// Every header and record is one NUL-terminated token, except `2` (rename/copy) records, whose original path
/// follows as the next token. Fixed fields are separated by a single space; the path is the rest of the token, so
/// spaces, tabs and line feeds in file names are kept as is. Unknown headers are ignored and unknown record kinds
/// are counted in `skippedRecords`; a known record whose fields do not match fails the whole parse (§1.6).
///
/// The bytes are scanned once in place (`memchr` over the raw buffer, index ranges instead of `Data` slices) so
/// that 100k records stay under a second even in unoptimized builds (§1.9).
enum StatusParser {
    fileprivate static let name = "StatusParser"

    static func parse(_ data: Data, truncated: Bool = false) throws -> WorkingState {
        try data.withUnsafeBytes { buffer in
            var reader = StatusReader(bytes: buffer)
            return try reader.read(truncated: truncated)
        }
    }
}

/// A byte range inside the output buffer.
private typealias Span = Range<Int>

private enum ASCII {
    static let nul: UInt8 = 0x00
    static let space: UInt8 = 0x20
    static let dot = UInt8(ascii: ".")
}

private struct StatusReader {
    let bytes: UnsafeRawBufferPointer
    /// Start of the token being read, for error offsets.
    private var tokenStart = 0
    private var headCommit: ObjectID??
    private var head: WorkingState.Head?
    private var upstream: String?
    private var aheadBehind: (ahead: Int, behind: Int)?
    private var stashCount = 0
    private var staged: [FileChange] = []
    private var unstaged: [FileChange] = []
    private var untracked: [FileChange] = []
    private var conflicted: [FileChange] = []
    private var skippedRecords = 0

    init(bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

    mutating func read(truncated: Bool) throws -> WorkingState {
        let tokens = try tokens(truncated: truncated)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            tokenStart = token.lowerBound
            guard !token.isEmpty else { throw failure("empty token") }
            switch bytes[token.lowerBound] {
            case UInt8(ascii: "#"):
                try header(token)
            case UInt8(ascii: "1"):
                try ordinary(body(of: token))
            case UInt8(ascii: "2"):
                guard index + 1 < tokens.count else {
                    if truncated { break }  // the original path was cut off: drop the record
                    throw failure("rename record without an original path")
                }
                try renamed(body(of: token), originalPath: tokens[index + 1])
                index += 1
            case UInt8(ascii: "u"):
                try unmerged(body(of: token))
            case UInt8(ascii: "?"):
                try untracked(body(of: token))
            case UInt8(ascii: "!"):
                break  // ignored files are not requested; skip them if they appear
            default:
                skippedRecords += 1
            }
            index += 1
        }
        return try build(isPartial: truncated)
    }

    // MARK: Tokens

    /// Splits on NUL. Untruncated output must end with NUL; truncated output loses its last token, which may be cut
    /// (§1.5). Dropping a complete last token too is deliberate: a cut exactly at a NUL is indistinguishable.
    private func tokens(truncated: Bool) throws -> [Span] {
        var tokens: [Span] = []
        var start = 0
        var hasUnterminatedTail = false
        while start < bytes.count {
            guard let end = find(ASCII.nul, in: start..<bytes.count) else {
                tokens.append(start..<bytes.count)
                hasUnterminatedTail = true
                break
            }
            tokens.append(start..<end)
            start = end + 1
        }
        if hasUnterminatedTail, !truncated {
            throw ParseError(parser: StatusParser.name, offset: bytes.count, reason: "output does not end with NUL")
        }
        if truncated, !tokens.isEmpty { tokens.removeLast() }
        return tokens
    }

    /// The record after its one-byte kind and the separating space.
    private func body(of token: Span) throws -> Span {
        guard token.count >= 2, bytes[token.lowerBound + 1] == ASCII.space else {
            throw failure("record kind without a space")
        }
        return (token.lowerBound + 2)..<token.upperBound
    }

    // MARK: Headers (§3.1)

    private mutating func header(_ token: Span) throws {
        // Branch names go back to git as arguments, so a lossy decode would name a different ref. Unknown headers
        // with invalid UTF-8 are still ignored (§1.6).
        guard let text = strictString(token) else {
            if string(token).hasPrefix("# branch.") { throw failure("invalid UTF-8 branch header") }
            return
        }
        guard text.hasPrefix("# ") else { return }  // unknown header shape
        let rest = text.dropFirst(2)
        let key = rest.prefix { $0 != " " }
        let value = key.endIndex < rest.endIndex ? String(rest[rest.index(after: key.endIndex)...]) : nil
        switch key {
        case "branch.oid": headCommit = try headerOID(value)
        case "branch.head":
            let name = try nonEmpty(value, "branch.head")
            head = name == "(detached)" ? .detached : .branch(name)
        case "branch.upstream": upstream = try nonEmpty(value, "branch.upstream")
        case "branch.ab": aheadBehind = try headerAheadBehind(value)
        case "stash":
            guard let value, let count = decimal(value) else { throw failure("bad stash count") }
            stashCount = count
        default: return  // forward compatibility (§1.6)
        }
    }

    private func headerOID(_ value: String?) throws -> ObjectID? {
        if value == "(initial)" { return nil }
        guard let value, let oid = ObjectID(value) else { throw failure("bad branch.oid") }
        return oid
    }

    /// `+<ahead> -<behind>`; the only signs allowed anywhere (§1.8).
    private func headerAheadBehind(_ value: String?) throws -> (ahead: Int, behind: Int) {
        let parts = value?.split(separator: " ", omittingEmptySubsequences: false) ?? []
        guard parts.count == 2, parts[0].first == "+", parts[1].first == "-",
            let ahead = decimal(parts[0].dropFirst()),
            let behind = decimal(parts[1].dropFirst())
        else { throw failure("bad branch.ab") }
        return (ahead, behind)
    }

    private func nonEmpty(_ value: String?, _ key: String) throws -> String {
        guard let value, !value.isEmpty else { throw failure("empty \(key)") }
        return value
    }

    // MARK: Records (§3.2, §3.3)

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
    private mutating func ordinary(_ body: Span) throws {
        let record = try fixedFields(body, count: 7, modes: 2...4, hashes: 5...6)
        let isSubmodule = try submodule(record.fields[1])
        let xy = record.fields[0].lowerBound
        if let status = try simpleStatus(bytes[xy]) {
            staged.append(FileChange(path: record.path, status: status, isSubmodule: isSubmodule))
        }
        if let status = try simpleStatus(bytes[xy + 1]) {
            unstaged.append(FileChange(path: record.path, status: status, isSubmodule: isSubmodule))
        }
    }

    /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>` followed by the original path token.
    /// The original path belongs to the side (index or worktree) that renamed or copied.
    private mutating func renamed(_ body: Span, originalPath: Span) throws {
        let record = try fixedFields(body, count: 8, modes: 2...4, hashes: 5...6)
        let isSubmodule = try submodule(record.fields[1])
        let xy = record.fields[0].lowerBound
        let scoreField = record.fields[7]
        let letter = bytes[scoreField.lowerBound]
        guard letter == UInt8(ascii: "R") || letter == UInt8(ascii: "C"),
            bytes[xy] == letter || bytes[xy + 1] == letter,
            let score = decimal(string(scoreField.dropFirst()))
        else { throw failure("bad rename score") }
        guard !originalPath.isEmpty else { throw failure("empty original path") }
        let original = path(originalPath)
        for (code, isIndex) in [(bytes[xy], true), (bytes[xy + 1], false)] {
            let isMove = code == UInt8(ascii: "R") || code == UInt8(ascii: "C")
            let status: FileChange.Status
            if isMove {
                status = code == UInt8(ascii: "R") ? .renamed(score: score) : .copied(score: score)
            } else if let simple = try simpleStatus(code) {
                status = simple
            } else {
                continue
            }
            let change = FileChange(
                path: record.path,
                originalPath: isMove ? original : nil,
                status: status,
                isSubmodule: isSubmodule
            )
            if isIndex { staged.append(change) } else { unstaged.append(change) }
        }
    }

    /// `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`
    private mutating func unmerged(_ body: Span) throws {
        let record = try fixedFields(body, count: 9, modes: 2...5, hashes: 6...8)
        let isSubmodule = try submodule(record.fields[1])
        guard let kind = ConflictKind(rawValue: string(record.fields[0])) else {
            throw failure("unknown conflict XY")
        }
        conflicted.append(FileChange(path: record.path, status: .conflicted(kind), isSubmodule: isSubmodule))
    }

    /// `? <path>`
    private mutating func untracked(_ body: Span) throws {
        guard !body.isEmpty else { throw failure("empty path") }
        untracked.append(FileChange(path: path(body), status: .untracked))
    }

    /// Splits `count` space-terminated fields off `body`; the rest is the path. Validates XY, modes and hashes.
    private func fixedFields(
        _ body: Span,
        count: Int,
        modes: ClosedRange<Int>,
        hashes: ClosedRange<Int>
    ) throws -> (fields: [Span], path: GitPath) {
        var fields: [Span] = []
        fields.reserveCapacity(count)
        var start = body.lowerBound
        for _ in 0..<count {
            guard let space = find(ASCII.space, in: start..<body.upperBound), space > start else {
                throw failure("missing fields or path")
            }
            fields.append(start..<space)
            start = space + 1
        }
        guard start < body.upperBound else { throw failure("missing fields or path") }
        guard fields[0].count == 2 else { throw failure("bad XY") }
        var index = modes.lowerBound
        while index <= modes.upperBound {
            guard isMode(fields[index]) else { throw failure("bad mode") }
            index += 1
        }
        index = hashes.lowerBound
        while index <= hashes.upperBound {
            guard isObjectID(fields[index]) else { throw failure("bad object ID") }
            index += 1
        }
        return (fields, path(start..<body.upperBound))
    }

    /// `N...` or `S<c><m><u>`.
    private func submodule(_ field: Span) throws -> Bool {
        guard field.count == 4 else { throw failure("bad submodule field") }
        let start = field.lowerBound
        let (kind, commit, modified, untracked) = (bytes[start], bytes[start + 1], bytes[start + 2], bytes[start + 3])
        let dot = ASCII.dot
        if kind == UInt8(ascii: "N"), commit == dot, modified == dot, untracked == dot { return false }
        guard kind == UInt8(ascii: "S"),
            commit == UInt8(ascii: "C") || commit == dot,
            modified == UInt8(ascii: "M") || modified == dot,
            untracked == UInt8(ascii: "U") || untracked == dot
        else { throw failure("bad submodule field") }
        return true
    }

    /// Status for one side of XY outside renames. `nil` means unchanged (`.`).
    private func simpleStatus(_ code: UInt8) throws -> FileChange.Status? {
        switch code {
        case ASCII.dot: nil
        case UInt8(ascii: "M"): .modified
        case UInt8(ascii: "T"): .typeChanged
        case UInt8(ascii: "A"): .added
        case UInt8(ascii: "D"): .deleted
        default: throw failure("bad XY")
        }
    }

    // MARK: Result

    private func build(isPartial: Bool) throws -> WorkingState {
        guard let headCommit else { throw ParseError(parser: StatusParser.name, offset: 0, reason: "no branch.oid") }
        guard let head else { throw ParseError(parser: StatusParser.name, offset: 0, reason: "no branch.head") }
        let upstreamStatus: UpstreamStatus =
            switch (upstream, aheadBehind) {
            case (nil, _): .none
            case (let name?, nil): .gone(upstream: name)
            case (let name?, let counts?): .tracking(upstream: name, ahead: counts.ahead, behind: counts.behind)
            }
        return WorkingState(
            headCommit: headCommit,
            head: head,
            upstream: upstreamStatus,
            stashCount: stashCount,
            staged: staged,
            unstaged: unstaged,
            untracked: untracked,
            conflicted: conflicted,
            isPartial: isPartial,
            skippedRecords: skippedRecords
        )
    }

    // MARK: Byte helpers

    private func failure(_ reason: String) -> ParseError {
        ParseError(parser: StatusParser.name, offset: tokenStart, reason: reason)
    }

    private func find(_ byte: UInt8, in span: Span) -> Int? {
        guard !span.isEmpty, let base = bytes.baseAddress,
            let found = memchr(base + span.lowerBound, Int32(byte), span.count)
        else { return nil }
        return base.distance(to: UnsafeRawPointer(found))
    }

    private func string(_ span: Span) -> String {
        String(decoding: UnsafeRawBufferPointer(rebasing: bytes[span]), as: UTF8.self)
    }

    private func strictString(_ span: Span) -> String? {
        String(bytes: UnsafeRawBufferPointer(rebasing: bytes[span]), encoding: .utf8)
    }

    private func path(_ span: Span) -> GitPath {
        GitPath(raw: Data(UnsafeRawBufferPointer(rebasing: bytes[span])))
    }

    /// Six octal digits, e.g. `100644`, `160000`, `000000`.
    private func isMode(_ span: Span) -> Bool {
        guard span.count == 6, let base = typedBase else { return false }
        var index = span.lowerBound
        while index < span.upperBound {
            let byte = base[index]
            guard byte >= 0x30, byte <= 0x37 else { return false }
            index += 1
        }
        return true
    }

    /// 40 or 64 lowercase hex digits (§1.7), checked on bytes to avoid a `String` per hash.
    private func isObjectID(_ span: Span) -> Bool {
        guard span.count == 40 || span.count == 64, let base = typedBase else { return false }
        var index = span.lowerBound
        while index < span.upperBound {
            let byte = base[index]
            guard (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66) else { return false }
            index += 1
        }
        return true
    }

    /// Byte checks use plain pointer loops: range iterators, closures and `ClosedRange.contains` are generic calls
    /// per byte in debug builds, which made 100k records take over a second there.
    private var typedBase: UnsafePointer<UInt8>? { bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) }

    /// Unsigned decimal only (§1.8). `Int("+1")` would accept a sign, so digits are checked first.
    private func decimal(_ text: some StringProtocol) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(text)
    }
}
