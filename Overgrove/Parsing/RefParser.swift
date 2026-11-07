import Foundation

/// Parses `git for-each-ref` output in the `ReadOnlyGitCommand.refs` format (parsing-spec.md §6).
///
/// Each record ends with LF and has eight NUL-separated fields: refname, objectname, `*objectname`, upstream, HEAD,
/// committer date, symref, and `upstream:track,nobracket`. Ref names cannot contain control characters, so LF is a
/// safe record separator.
///
/// Ref names go back to git as arguments, so they are never decoded lossily: a ref name, upstream, or symref target
/// that is not valid UTF-8 or fails `FullRefName` validation fails the whole parse, like any other malformed field.
/// Refs outside `refs/heads/`, `refs/remotes/` and `refs/tags/` are ignored.
enum RefParser {
    struct Listing: Sendable, Equatable {
        /// Local branches and remote-tracking refs, in git's order (sorted by ref name).
        let branches: [Branch]
        let tags: [Tag]
        /// The output was cut at the size limit and the last incomplete record was dropped.
        let isPartial: Bool
    }

    private static let name = "RefParser"
    private static let fieldCount = 8
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
        for line in lines {
            switch try record(line, in: data) {
            case .branch(let branch): branches.append(branch)
            case .tag(let tag): tags.append(tag)
            case .ignored: continue
            }
        }
        return Listing(branches: branches, tags: tags, isPartial: truncated)
    }
}

extension RefParser {
    private enum Record {
        case branch(Branch)
        case tag(Tag)
        case ignored
    }

    private static func record(_ line: Token, in data: Data) throws -> Record {
        let fields = line.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count == fieldCount else {
            throw ParseError(parser: name, offset: offset(of: line, in: data), reason: "expected \(fieldCount) fields")
        }
        let refname = try refName(fields[0], reason: "invalid ref name", in: data)
        let target = try objectID(fields[1], reason: "invalid object name", in: data)
        let peeled = fields[2].isEmpty ? nil : try objectID(fields[2], reason: "invalid peeled object name", in: data)
        let upstream = fields[3].isEmpty ? nil : try refName(fields[3], reason: "invalid upstream", in: data)
        let isHead = try headMarker(fields[4], in: data)
        let date = try committerDate(fields[5], in: data)
        let symref = fields[6].isEmpty ? nil : try refName(fields[6], reason: "invalid symref target", in: data)
        let upstreamStatus = try track(fields[7], upstream: upstream, in: data)

        if refname.hasPrefix(tagsPrefix) {
            return .tag(Tag(fullName: refname, target: target, peeledTarget: peeled, date: date))
        }
        let kind: Branch.Kind
        if refname.hasPrefix(headsPrefix) {
            kind = .local
        } else if refname.hasPrefix(remotesPrefix) {
            // Remote names may contain `/`; without the configured remotes, the first component is the best guess.
            let rest = refname.dropFirst(remotesPrefix.count)
            kind = .remote(remote: String(rest.prefix { $0 != "/" }))
        } else {
            return .ignored
        }
        return .branch(
            Branch(
                fullName: refname,
                kind: kind,
                target: target,
                upstreamStatus: upstreamStatus,
                isHead: isHead,
                committerDate: date,
                symbolicTarget: symref
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

    /// A full ref name that can be passed back to git unchanged: valid UTF-8 and accepted by `FullRefName`.
    private static func refName(_ token: Token, reason: String, in data: Data) throws -> String {
        guard let text = String(data: Data(token), encoding: .utf8), FullRefName.isValid(text) else {
            throw fail(token, reason, in: data)
        }
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
    /// An empty value means "in sync" when an upstream is set and "no upstream" otherwise.
    private static func track(_ token: Token, upstream: String?, in data: Data) throws -> UpstreamStatus {
        guard let upstream else {
            guard token.isEmpty else { throw fail(token, "track without upstream", in: data) }
            return .none
        }
        if token.isEmpty { return .tracking(upstream: upstream, ahead: 0, behind: 0) }
        if token.elementsEqual("gone".utf8) { return .gone(upstream: upstream) }

        let invalid = fail(token, "invalid upstream track", in: data)
        let parts = token.split(separator: Data(", ".utf8), omittingEmptySubsequences: false)
        var ahead = 0
        var behind = 0
        switch parts.count {
        case 1:
            if let count = count(parts[0], label: "ahead") {
                ahead = count
            } else if let count = count(parts[0], label: "behind") {
                behind = count
            } else {
                throw invalid
            }
        case 2:
            guard let aheadCount = count(parts[0], label: "ahead"), let behindCount = count(parts[1], label: "behind")
            else { throw invalid }
            ahead = aheadCount
            behind = behindCount
        default:
            throw invalid
        }
        return .tracking(upstream: upstream, ahead: ahead, behind: behind)
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
