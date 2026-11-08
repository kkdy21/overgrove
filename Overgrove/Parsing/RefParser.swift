import Foundation

/// Parses `git for-each-ref` output in the `ReadOnlyGitCommand.refs` format (parsing-spec.md §6).
///
/// Each record ends with LF and has ten NUL-separated fields: refname, objectname, `*objectname`, upstream, HEAD,
/// committer date, symref, `upstream:track,nobracket`, `upstream:remotename`, and `upstream:remoteref`. Ref names cannot contain control characters, so LF is a
/// safe record separator.
///
/// Format violations (field count, OIDs, HEAD marker, numbers, track syntax) fail the whole parse: a shifted field
/// would show wrong information (parsing-spec.md §1.6).
///
/// Ref names go back to git as arguments, so they are never decoded lossily. git allows names that cannot be passed
/// back (invalid UTF-8, or rejected by `FullRefName`), so one hostile ref must not hide every other one:
/// - such a ref name or upstream skips the record and counts it in `skippedRecords` (the UI shows a non-blocking
///   warning). A branch is not shown as "no upstream" when it has one;
/// - such a symref target becomes `symbolicTarget == nil`.
///
/// Refs outside `refs/heads/`, `refs/remotes/` and `refs/tags/` are ignored without being counted.
enum RefParser {
    struct Listing: Sendable, Equatable {
        /// Local branches and remote-tracking refs, in git's order (sorted by ref name).
        let branches: [Branch]
        let tags: [Tag]
        /// The output was cut at the size limit and the last incomplete record was dropped.
        let isPartial: Bool
        /// Records whose ref name or upstream cannot be passed back to git losslessly.
        let skippedRecords: Int
    }

    private static let name = "RefParser"
    private static let fieldCount = 10
    private static let lineFeed = UInt8(ascii: "\n")

    private static let headsPrefix = "refs/heads/"
    private static let remotesPrefix = "refs/remotes/"
    private static let tagsPrefix = "refs/tags/"

    private typealias Token = Data.SubSequence

    static func parse(_ data: Data, truncated: Bool = false) throws -> Listing {
        var lines = data.split(separator: lineFeed, omittingEmptySubsequences: false)
        // After the final LF, `split` yields one more token: empty when the output is complete, otherwise a record
        // that was cut off.
        let tail = lines.removeLast()
        if !tail.isEmpty, !truncated {
            throw ParseError(parser: name, offset: offset(of: tail, in: data), reason: "unterminated record")
        }

        var branches: [Branch] = []
        var tags: [Tag] = []
        var skippedRecords = 0
        for line in lines {
            switch try record(line, in: data) {
            case .branch(let branch): branches.append(branch)
            case .tag(let tag): tags.append(tag)
            case .unrepresentable: skippedRecords += 1
            case .ignored: continue
            }
        }
        return Listing(branches: branches, tags: tags, isPartial: truncated, skippedRecords: skippedRecords)
    }
}

extension RefParser {
    private enum Record {
        case branch(Branch)
        case tag(Tag)
        /// A ref name or upstream that cannot go back to git.
        case unrepresentable
        case ignored
    }

    private enum Track {
        case inSync
        case gone
        case counts(ahead: Int, behind: Int)
    }

    private static func record(_ line: Token, in data: Data) throws -> Record {
        let fields = line.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count == fieldCount else {
            throw ParseError(parser: name, offset: offset(of: line, in: data), reason: "expected \(fieldCount) fields")
        }
        // Format checks come first and apply to every record, including ones skipped below.
        let target = try objectID(fields[1], reason: "invalid object name", in: data)
        let peeled = fields[2].isEmpty ? nil : try objectID(fields[2], reason: "invalid peeled object name", in: data)
        let isHead = try headMarker(fields[4], in: data)
        let date = try committerDate(fields[5], in: data)
        let track = try track(fields[7], hasUpstream: !fields[3].isEmpty, in: data)

        let kind: Branch.Kind?
        if fields[0].starts(with: tagsPrefix.utf8) {
            kind = nil
        } else if fields[0].starts(with: headsPrefix.utf8) {
            kind = .local
        } else if fields[0].starts(with: remotesPrefix.utf8) {
            // Remote names may contain `/`; without the configured remotes, the first component is the best guess.
            let rest = fields[0].dropFirst(remotesPrefix.utf8.count)
            kind = .remote(remote: String(decoding: rest.prefix { $0 != UInt8(ascii: "/") }, as: UTF8.self))
        } else {
            return .ignored
        }
        guard let refname = refName(fields[0]) else { return .unrepresentable }
        guard let kind else {
            return .tag(Tag(fullName: refname, target: target, peeledTarget: peeled, date: date))
        }

        let upstreamStatus: UpstreamStatus
        if fields[3].isEmpty {
            upstreamStatus = .none
        } else {
            guard let upstream = refName(fields[3]) else { return .unrepresentable }
            upstreamStatus = status(track, upstream: upstream)
        }
        let symref = refName(fields[6])
        return .branch(
            Branch(
                fullName: refname,
                kind: kind,
                target: target,
                upstreamStatus: upstreamStatus,
                isHead: isHead,
                committerDate: date,
                symbolicTarget: symref,
                // Only matched against gh's head branch (ADR-0023 §4), never passed back to git.
                upstreamRemote: kind == .local ? utf8(fields[8]) : nil,
                upstreamRemoteRef: kind == .local ? utf8(fields[9]) : nil
            )
        )
    }

    // MARK: - Fields

    private static func offset(of token: Token, in data: Data) -> Int {
        token.startIndex - data.startIndex
    }

    private static func fail(_ token: Token, _ reason: String, in data: Data) -> ParseError {
        ParseError(parser: name, offset: offset(of: token, in: data), reason: reason)
    }

    /// Valid UTF-8 text, or `nil` when empty or not UTF-8.
    private static func utf8(_ token: Token) -> String? {
        token.isEmpty ? nil : String(data: Data(token), encoding: .utf8)
    }

    /// A full ref name that can be passed back to git unchanged (valid UTF-8, accepted by `FullRefName`), or `nil`.
    private static func refName(_ token: Token) -> String? {
        guard let text = String(data: Data(token), encoding: .utf8), FullRefName.isValid(text) else { return nil }
        return text
    }

    private static func objectID(_ token: Token, reason: String, in data: Data) throws -> ObjectID {
        guard let oid = ObjectID(String(decoding: token, as: UTF8.self)) else { throw fail(token, reason, in: data) }
        return oid
    }

    /// `*` for the branch checked out in the main worktree, a single space otherwise.
    private static func headMarker(_ token: Token, in data: Data) throws -> Bool {
        if token.elementsEqual([UInt8(ascii: "*")]) { return true }
        if token.elementsEqual([UInt8(ascii: " ")]) { return false }
        throw fail(token, "invalid HEAD marker", in: data)
    }

    /// Epoch seconds, or empty for objects without a committer (tag objects).
    private static func committerDate(_ token: Token, in data: Data) throws -> Date? {
        guard !token.isEmpty else { return nil }
        guard let seconds = unsignedDecimal(token) else { throw fail(token, "invalid committer date", in: data) }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// `%(upstream:track,nobracket)` under `LC_ALL=C`: empty, `ahead N`, `behind M`, `ahead N, behind M`, or `gone`.
    /// Only a branch with an upstream has a track value; empty then means "in sync". Without an upstream the result
    /// is unused.
    private static func track(_ token: Token, hasUpstream: Bool, in data: Data) throws -> Track {
        guard hasUpstream else {
            guard token.isEmpty else { throw fail(token, "track without upstream", in: data) }
            return .inSync
        }
        if token.isEmpty { return .inSync }
        if token.elementsEqual("gone".utf8) { return .gone }

        let invalid = fail(token, "invalid upstream track", in: data)
        let parts = token.split(separator: Data(", ".utf8), omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            if let ahead = count(parts[0], label: "ahead") { return .counts(ahead: ahead, behind: 0) }
            if let behind = count(parts[0], label: "behind") { return .counts(ahead: 0, behind: behind) }
            throw invalid
        case 2:
            guard let ahead = count(parts[0], label: "ahead"), let behind = count(parts[1], label: "behind")
            else { throw invalid }
            return .counts(ahead: ahead, behind: behind)
        default:
            throw invalid
        }
    }

    private static func status(_ track: Track, upstream: String) -> UpstreamStatus {
        switch track {
        case .inSync: .tracking(upstream: upstream, ahead: 0, behind: 0)
        case .gone: .gone(upstream: upstream)
        case .counts(let ahead, let behind): .tracking(upstream: upstream, ahead: ahead, behind: behind)
        }
    }

    /// `<label> <unsigned decimal>`, or `nil`.
    private static func count(_ part: Token, label: String) -> Int? {
        let prefix = Data((label + " ").utf8)
        guard part.starts(with: prefix) else { return nil }
        return unsignedDecimal(part.dropFirst(prefix.count))
    }

    /// ASCII digits only, no sign or whitespace (parsing-spec.md §1.8); `nil` when empty or out of range.
    private static func unsignedDecimal(_ token: Token) -> Int? {
        guard !token.isEmpty, token.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(String(decoding: token, as: UTF8.self))
    }
}
